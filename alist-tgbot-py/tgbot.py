import requests
import sys
import re
import logging
import os
import asyncio
import ast
import math
import html
from datetime import datetime
from dotenv import load_dotenv
from functools import wraps
from telegram import Update
from telegram.constants import ParseMode, ChatAction
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes
# 加载 .env 文件中的环境变量
load_dotenv()
# 配置日志
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)
# --- 从环境变量加载配置 ---
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
BASE_URL = os.getenv("ALIST_BASE_URL")
USERNAME = os.getenv("ALIST_USERNAME")
PASSWORD = os.getenv("ALIST_PASSWORD")
OFFLINE_DOWNLOAD_DIR = os.getenv("ALIST_OFFLINE_DIR")
SEARCH_URL = os.getenv("JAV_SEARCH_API")
ALLOWED_USER_IDS_STR = os.getenv("ALLOWED_USER_IDS")
# --- 配置校验 ---
if not all([TELEGRAM_TOKEN, BASE_URL, USERNAME, PASSWORD, OFFLINE_DOWNLOAD_DIR, SEARCH_URL, ALLOWED_USER_IDS_STR]):
    logger.error("错误：环境变量缺失！请检查 .env 文件或环境变量设置。")
    sys.exit(1)
try:
    # 将逗号分隔的字符串转换为整数集合
    ALLOWED_USER_IDS = set(map(int, ALLOWED_USER_IDS_STR.split(',')))
    logger.info(f"允许的用户 ID: {ALLOWED_USER_IDS}")
except ValueError:
    logger.error("错误: ALLOWED_USER_IDS 格式不正确，请确保是逗号分隔的数字。")
    sys.exit(1)
# --- 全局token缓存 ---
# 使用 context.bot_data 来存储 token，更适合 PTB v20+
# global_token = None # 不再使用全局变量
# --- 用户授权装饰器 ---
def restricted(func):
    @wraps(func)
    async def wrapped(update: Update, context: ContextTypes.DEFAULT_TYPE, *args, **kwargs):
        user_id = update.effective_user.id
        if user_id not in ALLOWED_USER_IDS:
            logger.warning(f"未授权用户尝试访问: {user_id}")
            await update.message.reply_text("抱歉，您没有权限使用此机器人。")
            return
        # 检查并获取 token，存储在 bot_data 中
        token = await get_token(context)
        if not token:
             await update.message.reply_text("错误: 无法连接或登录到 Alist 服务。")
             return
        # 将 token 传递给处理函数
        return await func(update, context, token=token, *args, **kwargs)
    return wrapped
# --- API 函数 ---
def parse_size_to_bytes(size_str: str) -> int | None:
    """Converts size string (e.g., '5.40GB', '1.25MB') to bytes."""
    if not size_str:
        return 0 # Treat empty size as 0 bytes
    size_str = size_str.upper()
    match = re.match(r'^([\d.]+)\s*([KMGTPEZY]?B)$', size_str)
    if not match:
        logger.warning(f"无法解析文件大小: {size_str}")
        return None # Indicate parsing failure
    value, unit = match.groups()
    try:
        value = float(value)
    except ValueError:
        logger.warning(f"无法解析文件大小值: {value} from {size_str}")
        return None
    unit = unit.upper()
    exponent = 0
    if unit.startswith('K'):
        exponent = 1
    elif unit.startswith('M'):
        exponent = 2
    elif unit.startswith('G'):
        exponent = 3
    elif unit.startswith('T'):
        exponent = 4
    # Add more if needed (P, E, Z, Y)
    return int(value * (1024 ** exponent))
# --- Helper Function to Parse Data Entry ---
def parse_api_data_entry(entry_str: str) -> dict | None:
    """Parses a single string entry from the API data list."""
    try:
        # Safely evaluate the string representation of the list
        data_list = ast.literal_eval(entry_str)
        if not isinstance(data_list, list) or len(data_list) < 4:
            logger.warning(f"解析后的数据格式不正确 (非列表或长度不足): {data_list}")
            return None
        magnet = data_list[0]
        name = data_list[1]
        size_str = data_list[2]
        date_str = data_list[3] # YYYY-MM-DD
        if not magnet or not magnet.startswith("magnet:?"):
            logger.warning(f"条目中缺少有效的磁力链接: {entry_str}")
            return None
        size_bytes = parse_size_to_bytes(size_str)
        if size_bytes is None: # Handle parsing failure
             logger.warning(f"无法解析大小，跳过条目: {entry_str}")
             return None # Skip entry if size is unparseable
        # Parse date safely
        upload_date = None
        try:
            if date_str:
                upload_date = datetime.strptime(date_str, '%Y-%m-%d').date()
        except ValueError:
            logger.warning(f"无法解析日期 '{date_str}'，日期将为 None")
        return {
            "magnet": magnet,
            "name": name,
            "size_str": size_str,
            "size_bytes": size_bytes,
            "date_str": date_str,
            "date": upload_date,
            "original_string": entry_str # Keep original for logging if needed
        }
    except (ValueError, SyntaxError, TypeError) as e:
        logger.error(f"解析 API 数据条目时出错: '{entry_str[:100]}...', 错误: {e}")
        return None
def get_magnet(fanhao, search_url):
    try:
        url = search_url.rstrip('/') + "/" + fanhao
        logger.info(f"正在搜索番号: {fanhao} 使用 URL: {url}")
        response = requests.get(url, timeout=20)
        response.raise_for_status()
        try:
            raw_result = response.json()
            logger.debug(f"API 原始响应文本 ({fanhao}): {response.text}")
            logger.debug(f"API 解析后的 JSON ({fanhao}): {raw_result}")
        except requests.exceptions.JSONDecodeError:
            logger.error(f"错误: API ({url}) 返回的不是有效的 JSON。响应内容: {response.text}")
            return None, "搜索服务暂时不可用 (返回格式错误)"
        if not raw_result or raw_result.get("status") != "succeed" or not raw_result.get("data") or not isinstance(raw_result.get("data"), list) or len(raw_result["data"]) == 0:
            logger.warning(f"API 响应未通过成功条件检查或未找到结果 ({fanhao}). Data: {raw_result}")
            error_msg = raw_result.get('message', '未知API错误') if isinstance(raw_result, dict) else '响应格式错误'
            if raw_result and raw_result.get("status") != "succeed":
                 return None, f"搜索服务报告错误 (状态: {raw_result.get('status', '未知')})"
            else:
                 return None, f"未能找到番号 '{fanhao}' 对应的资源"
        # --- Magnet Selection Logic ---
        parsed_entries = []
        for entry_str in raw_result["data"]:
            parsed = parse_api_data_entry(entry_str)
            if parsed:
                parsed_entries.append(parsed)
        if not parsed_entries:
            logger.error(f"错误: 成功获取 API 数据，但无法解析任何有效条目 ({fanhao})")
            return None, "找到了资源，但无法解析其详细信息"
        # Find max size for clustering heuristic
        max_size = 0
        for entry in parsed_entries:
             if entry["size_bytes"] > max_size:
                 max_size = entry["size_bytes"]
        if max_size == 0: # Handle case where all sizes are 0 or unparseable
             logger.warning(f"无法确定最大文件大小，将使用第一个有效磁链 ({fanhao})")
             return parsed_entries[0]["magnet"], None # Fallback: return the first one found
	# 定义 HD 集群阈值（例如，> 最大尺寸的 70%）
	# 如果需要，根据典型的尺寸差异调整此阈值 (0.7)
        hd_threshold = max_size * 0.7
        hd_cluster = [entry for entry in parsed_entries if entry["size_bytes"] >= hd_threshold]
        selected_cluster = hd_cluster
        if not hd_cluster:
            logger.info(f"未找到明显的高清版本 (大小 > {hd_threshold / (1024**3):.2f} GB)，将在所有版本中选择 ({fanhao})")
            selected_cluster = parsed_entries # Fallback to all entries if no HD cluster
        if not selected_cluster: # Should not happen if parsed_entries was not empty, but safety check
             logger.error(f"错误: 无法确定选择集群 ({fanhao})")
             return None, "筛选磁力链接时出错"
		# 对所选集群进行排序：
		# 1. 尺寸最小的优先（在集群内）
		# 2. 日期最新的优先（作为并列项的打破规则 - 按照示例分析使用最新的）
		#    对于没有日期的条目，使用非常旧的日期，以便它们在并列打破规则中排在最后。
        epoch_start_date = datetime(1970, 1, 1).date()
        selected_cluster.sort(key=lambda x: (x["size_bytes"], -(x["date"].toordinal() if x["date"] else epoch_start_date.toordinal())))
        chosen_entry = selected_cluster[0]
        chosen_magnet = chosen_entry["magnet"]
        logger.info(f"智能选择完成 ({fanhao}):")
        logger.info(f" - 总共解析条目: {len(parsed_entries)}")
        logger.info(f" - 最大检测大小: {max_size / (1024**3):.2f} GB")
        if hd_cluster:
            logger.info(f" - 高清集群条目数 (> {hd_threshold / (1024**3):.2f} GB): {len(hd_cluster)}")
        logger.info(f" - 选择标准: {'高清集群' if hd_cluster else '所有版本'}内，优先最小体积，其次最新日期")
        logger.info(f" - 最终选择: {chosen_entry['name']} ({chosen_entry['size_str']}, {chosen_entry['date_str']})")
        logger.info(f" - 磁力链接: {chosen_magnet[:60]}...")
        return chosen_magnet, None
        # --- End Magnet Selection Logic ---
    except requests.exceptions.Timeout:
        logger.error(f"获取磁力链接时超时 ({fanhao})")
        return None, "搜索番号超时，请稍后再试"
    except requests.exceptions.RequestException as e:
        logger.error(f"获取磁力链接时网络出错 ({fanhao}): {str(e)}")
        return None, "搜索服务连接失败，请检查网络或稍后再试"
    except Exception as e:
        logger.error(f"获取磁力链接时发生未知错误 ({fanhao}): {str(e)}", exc_info=True)
        return None, "搜索过程中发生内部错误"
async def get_token(context: ContextTypes.DEFAULT_TYPE) -> str | None:
    """获取 Alist Token，优先从 context.bot_data 获取，否则登录获取"""
    bot_data = context.bot_data
    token = bot_data.get("alist_token")
    if token:
        # 可选：在这里添加一个简单的测试请求来验证 token 是否仍然有效
        # 如果无效，设置 token = None，强制重新登录
        logger.info("使用缓存的 Alist token")
        return token
    try:
        url = BASE_URL.rstrip('/') + "/api/auth/login"
        logger.info("缓存 token 无效或不存在，正在登录获取新的 Alist token...")
        login_info = {"username": USERNAME, "password": PASSWORD}
        loop = asyncio.get_running_loop() # 获取当前事件循环
        response = await loop.run_in_executor( 
            None, # 使用默认的 executor
            lambda: requests.post(url, json=login_info, timeout=15)
        )
        response.raise_for_status()
        result = response.json()
        if result.get("code") == 200 and result.get("data") and result["data"].get("token"):
            token = str(result['data']['token'])
            logger.info("登录 Alist 成功，已获取并缓存 token")
            bot_data["alist_token"] = token  # 缓存 token
            return token
        else:
            error_msg = result.get('message', '未知错误')
            logger.error(f"Alist 登录失败: {error_msg} (Code: {result.get('code', 'N/A')})")
            return None
    except requests.exceptions.RequestException as e:
        logger.error(f"登录 Alist 获取 token 时出错: {str(e)}")
        return None
    except Exception as e:
        logger.error(f"登录 Alist 过程中发生未知错误: {str(e)}", exc_info=True)
        return None
async def add_magnet(context: ContextTypes.DEFAULT_TYPE, token: str, magnet: str) -> tuple[bool, str]:
    """使用 'storage' 工具添加磁力链接到 Alist 离线下载"""
    if not token or not magnet:
        logger.error("错误: token 或磁力链接为空")
        # 返回符合 (bool, str) 格式的错误信息
        return False, "内部错误：Token 或磁力链接为空"
    try:
        # 使用全局变量 BASE_URL 和 OFFLINE_DOWNLOAD_DIR
        url = BASE_URL.rstrip('/') + "/api/fs/add_offline_download"
        logger.info(f"正在添加离线下载任务到目录: {OFFLINE_DOWNLOAD_DIR}")
        headers = {
            "Authorization": token,
            "Content-Type": "application/json"
        }
        # --- 修改 post_data ---
        post_data = {
            "path": OFFLINE_DOWNLOAD_DIR,
            "urls": [magnet],
            "tool": "storage",  # <--- 这里修改为 "storage"
            "delete_policy": "delete_on_upload_succeed" # 和你提供的示例一致
        }
        # --- 修改结束 ---
        loop = asyncio.get_running_loop() # 获取当前事件循环
        # --- 保留异步执行 ---
        response = await loop.run_in_executor(
             None, # 使用默认的 executor
             lambda: requests.post(url, json=post_data, headers=headers, timeout=30) # 增加超时时间
        )
        # --- 异步执行结束 ---
        if response.status_code == 401:
            logger.warning("Alist token 可能已过期或无效 (收到 401)")
            context.bot_data.pop("alist_token", None)
            # 用户友好的错误
            return False, "❌ Alist 认证失败，Token 可能已过期，请稍后重试"
        response.raise_for_status()
        result = response.json()
        if result.get("code") == 200:
            logger.info("离线下载任务添加成功!")
            # 成功的消息
            return True, "✅ 离线下载任务添加成功！"
        else:
            error_msg = result.get('message', '未知错误')
            logger.error(f"添加 Alist 离线下载任务失败: {error_msg} (Code: {result.get('code', 'N/A')})")
            # 用户友好的错误 - 从 Alist API 获取的消息可能已经比较清晰
            return False, f"❌ 添加任务失败: {error_msg}"
    except requests.exceptions.Timeout:
        logger.error("添加 Alist 离线下载任务时超时")
        # 用户友好的错误
        return False, "❌ 添加任务超时，请检查 Alist 服务状态"
    except requests.exceptions.RequestException as e:
        logger.error(f"添加 Alist 离线下载任务时出错: {str(e)}")
        if "Connection refused" in str(e) or "Failed to establish a new connection" in str(e):
             # 用户友好的错误
             return False, "❌ 添加任务失败: 无法连接到 Alist 服务，请检查其是否运行"
        # 用户友好的错误
        return False, f"❌ 添加任务时网络出错: 请检查网络连接或 Alist 地址"
    except Exception as e:
        logger.error(f"添加 Alist 离线下载任务时发生未知错误: {str(e)}", exc_info=True)
        # 用户友好的错误
        return False, "❌ 添加任务时发生内部错误"
async def find_download_directory(token: str, base_url: str, parent_dir: str, original_code: str) -> tuple[str | None, str | None]:
    """
    Searches for a directory within parent_dir that matches the original_code.
    Args:
        token: Alist auth token.
        base_url: Alist base URL.
        parent_dir: The base directory where downloads are stored (e.g., OFFLINE_DOWNLOAD_DIR).
        original_code: The code provided by the user (e.g., 'SONE-622').
    Returns:
        tuple[str | None, str | None]: (found_path, error_message)
        - If exactly one match is found, returns (full_path, None).
        - If no matches or multiple matches are found, or an error occurs, returns (None, error_message).
    """
    logger.info(f"在 '{parent_dir}' 中搜索与 '{original_code}' 匹配的目录...")
    list_url = base_url.rstrip('/') + "/api/fs/list"
    headers = {"Authorization": token, "Content-Type": "application/json"}
    list_payload = {"path": parent_dir, "page": 1, "per_page": 0} # Get all items
    try:
        loop = asyncio.get_running_loop()
        response_list = await loop.run_in_executor(
            None, lambda: requests.post(list_url, json=list_payload, headers=headers, timeout=20)
        )
        response_list.raise_for_status()
        list_result = response_list.json()
        if list_result.get("code") != 200 or not list_result.get("data") or list_result["data"].get("content") is None:
            msg = f"无法列出父目录 '{parent_dir}' 的内容: {list_result.get('message', '未知错误')}"
            logger.error(msg)
            return None, msg
        content = list_result["data"]["content"]
        if not content:
            msg = f"父目录 '{parent_dir}' 为空或无法访问。"
            logger.warning(msg)
            return None, msg
        possible_matches = []
        lower_code = original_code.lower()
        for item in content:
            if item.get("is_dir"):
                dir_name = item.get("name")
                if dir_name:
                    # Match if the directory name starts with the code (case-insensitive)
                    if dir_name.lower().startswith(lower_code):
                        # Construct the full path for the match
                        full_path = parent_dir.rstrip('/') + '/' + dir_name
                        possible_matches.append({"name": dir_name, "path": full_path})
                        logger.debug(f"找到潜在匹配目录: {full_path}")
        if len(possible_matches) == 1:
            found = possible_matches[0]
            logger.info(f"找到唯一匹配目录: {found['path']}")
            return found['path'], None
        elif len(possible_matches) == 0:
            msg = f"在 '{parent_dir}' 中未找到任何以 '{original_code}' 开头的目录。"
            logger.warning(msg)
            return None, msg
        else:
            match_names = [m['name'] for m in possible_matches]
            msg = f"找到多个可能的目录: {match_names}。请确认具体是哪一个或手动清理。"
            logger.warning(msg)
            return None, msg
    except requests.exceptions.Timeout:
        msg = f"查找目录时请求超时 (与 Alist 通信时)"
        logger.error(msg)
        return None, msg
    except requests.exceptions.RequestException as e:
        msg = f"查找目录时发生网络错误: {e}"
        logger.error(msg)
        return None, msg
    except Exception as e:
        msg = f"查找目录时发生未知错误: {e}"
        logger.error(msg, exc_info=True)
        return None, msg
# --- 广告文件清理函数 ---
# 定义广告文件的模式和关键词
# 根据观察，使这些内容更全面
AD_KEYWORDS = ["直播", "聚合", "社区", "情报", "最新地址", "獲取", "花式表演", "大全", "群淫傳", "三國志H版", "七龍珠H版"] # Add more common ad phrases
AD_DOMAINS = ["996gg.cc"] # Add known ad domains found in filenames
AD_EXTENSIONS = {".txt", ".html", ".htm", ".url", ".lnk", ".apk", ".exe"} # Extensions often used for ads/junk
MEDIA_EXTENSIONS = {".mp4", ".mkv", ".avi", ".wmv", ".mov", ".flv", ".rmvb"} # Common video extensions to keep
async def cleanup_ad_files(token: str, base_url: str, directory_path: str, original_code: str):
    """
    Lists files in a directory via Alist API, identifies, and deletes ad files.
    Args:
        token: Alist auth token.
        base_url: Alist base URL.
        directory_path: The path within Alist where the download finished.
        original_code: The original search code (e.g., 'SONE-622') used for identifying main files.
    Returns:
        tuple[bool, str]: (success_status, message)
    """
    logger.info(f"开始清理目录 '{directory_path}' 中的广告文件 (基于番号: {original_code})")
    list_url = base_url.rstrip('/') + "/api/fs/list"
    remove_url = base_url.rstrip('/') + "/api/fs/remove"
    headers = {"Authorization": token, "Content-Type": "application/json"}
    try:
        # 1. List files in the directory
        list_payload = {"path": directory_path, "page": 1, "per_page": 0} # Get all files
        loop = asyncio.get_running_loop()
        response_list = await loop.run_in_executor(
            None, lambda: requests.post(list_url, json=list_payload, headers=headers, timeout=20)
        )
        response_list.raise_for_status()
        list_result = response_list.json()
        if list_result.get("code") != 200 or not list_result.get("data") or list_result["data"].get("content") is None:
            msg = f"无法列出目录 '{directory_path}' 的内容: {list_result.get('message', '未知错误')}"
            logger.error(msg)
            return False, f"❌ 清理失败: {msg}"
        files_to_check = list_result["data"]["content"]
        if not files_to_check:
            logger.info(f"目录 '{directory_path}' 为空，无需清理。")
            return True, "✅ 目录为空，无需清理。"
        # Prepare original code for matching (lowercase, remove hyphen for broader match)
        match_code = original_code.lower().replace('-', '')
        files_to_delete = []
        files_kept = []
        # 2. Identify files to delete
        for file_info in files_to_check:
            if file_info.get("is_dir"): # Skip directories
                continue
            filename = file_info.get("name")
            if not filename:
                continue
            base_name, extension = os.path.splitext(filename)
            extension = extension.lower()
            lower_filename = filename.lower()
            lower_basename = base_name.lower()
            # Rule 1: Check if it's a primary media file to KEEP
            keep_file = False
            if extension in MEDIA_EXTENSIONS:
                # Check if filename contains the essential code part
                # (e.g., 'sone622' is in 'sone-622ch.mp4')
                # Make matching more robust if needed (e.g., allow only prefix/suffix)
                if match_code in lower_basename.replace('-', ''):
                    keep_file = True
                    files_kept.append(filename)
                    logger.debug(f"保留主媒体文件: {filename}")
            # Rule 2: If not explicitly kept, check if it matches AD criteria
            delete_file = False
            if not keep_file:
                if extension in AD_EXTENSIONS:
                    delete_file = True
                    logger.debug(f"标记删除 (广告扩展名): {filename}")
                elif any(keyword in filename for keyword in AD_KEYWORDS): # Check full name for keywords
                    delete_file = True
                    logger.debug(f"标记删除 (广告关键词): {filename}")
                elif any(domain in lower_filename for domain in AD_DOMAINS):
                    delete_file = True
                    logger.debug(f"标记删除 (广告域名): {filename}")
                # Add more specific rules if needed
            if delete_file:
                files_to_delete.append(filename)
        if not files_to_delete:
            logger.info(f"在 '{directory_path}' 中未找到需要删除的广告文件。保留的文件: {files_kept}")
            return True, "✅ 未找到广告文件，无需清理。"
        logger.info(f"准备删除以下文件: {files_to_delete}")
        # 3. Delete identified files
        deleted_count = 0
        delete_errors = []
        for filename_to_delete in files_to_delete:
             delete_payload = {
                "dir": directory_path,
                "names": [filename_to_delete]
            }
        try:
                response_remove = await loop.run_in_executor(
                    None, lambda: requests.post(remove_url, json=delete_payload, headers=headers, timeout=15)
                )
                remove_result = response_remove.json()
                if remove_result.get("code") == 200:
                    logger.info(f"成功删除文件: {os.path.join(directory_path, filename_to_delete)}")
                    deleted_count += 1
                else:
                    err_msg = f"删除 '{filename_to_delete}' 失败: {remove_result.get('message', '未知错误')} (Code: {remove_result.get('code')})"
                    logger.error(err_msg)
                    delete_errors.append(err_msg)
        except Exception as e:
                err_msg = f"删除 '{filename_to_delete}' 时发生请求错误: {e}"
                logger.error(err_msg, exc_info=True)
                delete_errors.append(err_msg)
        except Exception as e: # --- Check this inner except block ---
                # Ensure this except line is correctly indented relative to its 'try'
                err_msg = f"删除 '{filename_to_delete}' 时发生请求错误: {e}"
                 # Ensure the next two lines are correctly indented and have no syntax errors
                logger.error(err_msg, exc_info=True)
                delete_errors.append(err_msg)
        # 4. Report result
        if not delete_errors:
            msg = f"✅ 成功清理 {deleted_count} 个广告文件。"
            logger.info(msg + f" 保留的文件: {files_kept}")
            return True, msg
        else:
            msg = f"⚠️ 清理完成，但有 {len(delete_errors)} 个文件删除失败 (共识别 {len(files_to_delete)} 个)。成功删除 {deleted_count} 个。"
            logger.error(msg + f" 错误详情: {delete_errors}")
            return False, msg
    except requests.exceptions.Timeout:
        msg = f"清理操作超时 (与 Alist 通信时)"
        logger.error(msg)
        return False, f"❌ 清理失败: {msg}"
    except requests.exceptions.RequestException as e:
        msg = f"清理操作时发生网络错误: {e}"
        logger.error(msg)
        return False, f"❌ 清理失败: {msg}"
    except Exception as e:
        msg = f"清理操作时发生未知错误: {e}"
        logger.error(msg, exc_info=True)
        return False, f"❌ 清理失败: {msg}"
# --- Telegram 机器人命令处理函数 ---
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """发送开始消息"""
    user_id = update.effective_user.id
    if user_id not in ALLOWED_USER_IDS:
         await update.message.reply_text("抱歉，您没有权限使用此机器人。")
         return
    await update.message.reply_text(
        '欢迎使用 JAV 下载机器人！\n'
        '直接发送番号（如 ABC-123）或磁力链接，我会帮你添加到 Alist 离线下载。\n'
        '/help 查看帮助。'
    )
async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """发送帮助信息"""
    user_id = update.effective_user.id
    if user_id not in ALLOWED_USER_IDS:
         await update.message.reply_text("抱歉，您没有权限使用此机器人。")
         return
    await update.message.reply_text(
        '使用方法：\n'
        '1. 直接发送番号（例如：`ABC-123`, `IPX-888`）\n'
        '2. 直接发送磁力链接（以 `magnet:?` 开头）\n\n'
        '3. 使用/clean 加番号名清理广告文件（例如 /clean IPX-888）\n\n'
        '机器人会自动搜索番号对应的磁力链接（如果输入的是番号），然后将磁力链接添加到 Alist 的离线下载队列中。\n'
        f'当前配置的下载目录: `{OFFLINE_DOWNLOAD_DIR}`',
        parse_mode='Markdown'
    )
# 番号格式的简单正则表达式 (可以根据需要调整)
# 匹配常见的格式，如 XXX-123, XXX123, XXX 123
FANHAO_REGEX = re.compile(r'^[A-Za-z]{2,5}[- ]?\d{2,5}$', re.IGNORECASE)
@restricted # 应用权限检查和 token 获取
async def process_message(update: Update, context: ContextTypes.DEFAULT_TYPE, token: str) -> None:
    message_text = update.message.text.strip()
    magnet = None
    search_needed = False
    processing_msg = None # 初始化 processing_msg
    chat_id = update.effective_chat.id # 获取 chat_id 以便发送 action
    if message_text.startswith("magnet:?"):
        logger.info(f"收到磁力链接: {message_text[:50]}...")
        magnet = message_text
        # 发送初始消息
        processing_msg = await update.message.reply_text("🔗 收到磁力链接，准备添加...")
    elif FANHAO_REGEX.match(message_text):
        logger.info(f"收到可能的番号: {message_text}")
        search_needed = True
        # 发送初始消息
        processing_msg = await update.message.reply_text(f"🔍 正在搜索番号: {message_text}...")
        await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
        loop = asyncio.get_running_loop()
        try:
            magnet, error_msg = await loop.run_in_executor(
                None, lambda: get_magnet(message_text, SEARCH_URL)
            )
        except Exception as e:
             logger.error(f"执行 get_magnet 时发生意外错误: {e}", exc_info=True)
             magnet, error_msg = None, "搜索过程中发生内部错误"
        if not magnet:
            await processing_msg.edit_text(f"❌ 搜索失败: {error_msg}")
            return
        await processing_msg.edit_text(f"✅ 已找到磁力链接，正在添加到 Alist...")
    else:
        logger.warning(f"收到无法识别的消息格式: {message_text}")
        await update.message.reply_text("无法识别的消息格式。请发送番号（如 ABC-123）或磁力链接。")
        return
    await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
    success, result_msg = await add_magnet(context, token, magnet)
    if processing_msg:
        await processing_msg.edit_text(result_msg)
    else:
        # 如果是直接处理磁链且没有编辑对象，则回复
        await update.message.reply_text(result_msg)
@restricted # Apply permission check and token injection
async def clean_command(update: Update, context: ContextTypes.DEFAULT_TYPE, token: str) -> None:
    """
    Finds the download directory associated with a code and cleans ad files.
    Usage: /clean <CODE>
    Example: /clean SONE-622
    Searches in OFFLINE_DOWNLOAD_DIR for a folder starting with <CODE>.
    """
    if not context.args:
        await update.message.reply_text(
            "请提供要清理的番号代码。\n"
            "用法: `/clean <番号代码>`\n"
            "例如: `/clean SONE-622`\n"
            f"机器人将在 `{OFFLINE_DOWNLOAD_DIR}` 中搜索匹配的目录进行清理。",
            parse_mode='Markdown'
        )
        return
    original_code = context.args[0].strip()
    chat_id = update.effective_chat.id
    logger.info(f"收到清理请求: code='{original_code}', 基础目录='{OFFLINE_DOWNLOAD_DIR}'")
    # Send initial message and typing action
    processing_msg = await update.message.reply_text(f"🔍 正在查找与 '{original_code}' 匹配的下载目录...")
    await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
    # --- Step 1: Find the actual directory ---
    # Pass the BASE Alist URL and the PARENT download directory
    directory_to_clean, find_error = await find_download_directory(token, BASE_URL, OFFLINE_DOWNLOAD_DIR, original_code)
    if find_error:
        await processing_msg.edit_text(f"❌ 查找目录失败: {find_error}")
    # --- Step 2: If directory found, proceed with cleanup ---
    logger.info(f"找到目标目录 '{directory_to_clean}'，开始清理广告文件...")
    escaped_path = html.escape(directory_to_clean) # 转义 HTML 特殊字符
    await processing_msg.edit_text(
    f"🧹 已找到目录: <code>{escaped_path}</code>\n正在清理广告文件...", 
    parse_mode=ParseMode.HTML
)
    await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
    success, message = await cleanup_ad_files(token, BASE_URL, directory_to_clean, original_code)
    await processing_msg.edit_text(message)
def main() -> None:
    """启动机器人"""
    logger.info("开始初始化 Telegram 机器人...")
    # 创建应用
    application = Application.builder().token(TELEGRAM_TOKEN).build()
    # 添加处理程序
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("clean", clean_command)) # <-- 添加这一行
    # Message handler should remain last if it's a catch-all
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, process_message))
    # 启动机器人
    logger.info("启动 Telegram 机器人轮询...")
    application.run_polling(allowed_updates=Update.ALL_TYPES)
if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logger.critical(f"程序启动或运行过程中发生严重错误: {str(e)}", exc_info=True)
        sys.exit(1)
    finally:
        logger.info("Telegram 机器人已停止。")
