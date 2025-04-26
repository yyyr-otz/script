#!/bin/bash
pip install psutil selenium --break-system-packages
existing=$(crontab -l 2>/dev/null); if ! echo "$existing" | grep -q 'keep.py'; then (echo "$existing"; echo "*/20 * * * * /usr/bin/python /home/keep.py >> /home/keep.log 2>&1") | crontab -; fi
pip install psutil selenium --break-system-packages
export IDX_NAME=${IDX_NAME:-''}
cat > /home/keep.py << EOF
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
import logging
import os
import requests
import zipfile
import io

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S')

def download_chromedriver(version):
    """从Chrome for Testing下载最新驱动"""
    base_url = "https://storage.googleapis.com/chrome-for-testing-public"
    url = f"{base_url}/{version}/linux64/chromedriver-linux64.zip"
    try:
        logging.info(f"正在下载ChromeDriver {version}...")
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        with zipfile.ZipFile(io.BytesIO(response.content)) as z:
            with open("/usr/local/bin/chromedriver", "wb") as f:
                f.write(z.read("chromedriver-linux64/chromedriver"))
        os.chmod("/usr/local/bin/chromedriver", 0o755)
        logging.info("ChromeDriver安装成功")
    except Exception as e:
        logging.error(f"下载失败: {str(e)}")
        raise

def setup_environment():
    """检查并安装必要组件"""
    try:
        # 安装Chrome浏览器
        if os.system("google-chrome --version") != 0:
            logging.info("正在安装Google Chrome...")
            os.system("wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb")
            os.system("sudo apt install -y ./google-chrome-stable_current_amd64.deb")
        # 获取Chrome版本
        chrome_version = os.popen("google-chrome --version").read().strip().split()[-1]
        major_version = chrome_version.split(".")[0]
        # 下载对应ChromeDriver
        if not os.path.exists("/usr/local/bin/chromedriver"):
            download_chromedriver(chrome_version)
        else:
            # 验证版本是否匹配
            driver_version = os.popen("/usr/local/bin/chromedriver --version").read().strip().split()[1]
            if driver_version.split(".")[0] != major_version:
                download_chromedriver(chrome_version)
    except Exception as e:
        logging.error(f"环境设置失败: {str(e)}")
        exit(1)

def access_url(url: str):
    """访问指定URL后退出"""
    setup_environment()
    chrome_options = Options()
    chrome_options.add_argument(f"--user-data-dir=/home/user/.config/google-chrome")
    chrome_options.add_argument("--headless")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--mute-audio")
    driver = None
    try:
        service = Service(
            executable_path="/usr/local/bin/chromedriver",
            service_args=["--log-level=INFO"]
        )
        driver = webdriver.Chrome(service=service, options=chrome_options)
        driver.get(url)
        
        # 等待60秒，直到页面加载完成或重定向完成
        wait = WebDriverWait(driver, 60)
        wait.until(EC.presence_of_element_located((By.TAG_NAME, 'html')))
        
        logging.info(f"访问成功 | 最终URL: {driver.current_url}")
    except Exception as e:
        logging.error(f"访问异常: {str(e)}", exc_info=True)
    finally:
        if driver:
            driver.quit()

if __name__ == "__main__":
    target_url = "https://studio.firebase.google.com/${IDX_NAME}"
    access_url(target_url)
EOF
