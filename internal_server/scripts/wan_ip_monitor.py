#!/usr/bin/env python3
"""
WAN IP监控和自动更新服务 v2.0
监控WAN IP变化，自动更新LiveKit配置和Cloudflare DNS记录
"""

import os
import sys
import time
import json
import yaml
import logging
import requests
import subprocess
import configparser
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, List

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/wan-ip-monitor.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('wan-ip-monitor')

class WANIPMonitor:
    """WAN IP监控和更新服务"""
    
    def __init__(self, config_file: str = '/etc/wan-ip-monitor.conf'):
        """初始化监控服务"""
        self.config_file = config_file
        self.load_config()
        self.last_wan_ip = None
        self.last_check_time = None
        
    def load_config(self):
        """加载配置文件"""
        if not os.path.exists(self.config_file):
            logger.error(f"配置文件不存在: {self.config_file}")
            sys.exit(1)
            
        self.config = configparser.ConfigParser()
        self.config.read(self.config_file)
        
        # 获取配置参数
        self.check_interval = int(self.config.get('DEFAULT', 'check_interval', fallback='2'))
        self.routeros_ip = self.config.get('DEFAULT', 'routeros_ip', fallback='')
        self.routeros_username = self.config.get('DEFAULT', 'routeros_username', fallback='')
        self.routeros_password = self.config.get('DEFAULT', 'routeros_password', fallback='')
        self.livekit_config_path = self.config.get('DEFAULT', 'livekit_config_path')
        self.docker_compose_path = self.config.get('DEFAULT', 'docker_compose_path')
        self.cloudflare_api_token = self.config.get('DEFAULT', 'cloudflare_api_token')
        self.domains = self.config.get('DEFAULT', 'domains', fallback='').split(',')
        
        logger.info(f"配置加载完成，检查间隔: {self.check_interval}分钟")
    
    def get_wan_ip_from_routeros(self) -> Optional[str]:
        """从RouterOS获取WAN IP"""
        if not all([self.routeros_ip, self.routeros_username, self.routeros_password]):
            logger.debug("RouterOS配置不完整，跳过RouterOS API查询")
            return None
            
        try:
            # 使用RouterOS API获取WAN IP
            # 这里需要根据实际的RouterOS API实现
            # 暂时跳过，使用公共服务获取IP
            logger.debug("RouterOS API查询暂未实现，使用公共服务")
            return None
        except Exception as e:
            logger.warning(f"从RouterOS获取WAN IP失败: {e}")
            return None
    
    def get_wan_ip_from_public_services(self) -> Optional[str]:
        """从公共服务获取WAN IP"""
        services = [
            'https://ipv4.icanhazip.com',
            'https://api.ipify.org',
            'https://checkip.amazonaws.com',
            'https://ifconfig.me/ip'
        ]
        
        for service in services:
            try:
                response = requests.get(service, timeout=10)
                if response.status_code == 200:
                    wan_ip = response.text.strip()
                    # 验证IP格式
                    if self.is_valid_ip(wan_ip):
                        logger.debug(f"从 {service} 获取到WAN IP: {wan_ip}")
                        return wan_ip
            except Exception as e:
                logger.debug(f"从 {service} 获取WAN IP失败: {e}")
                continue
        
        return None
    
    def is_valid_ip(self, ip: str) -> bool:
        """验证IP地址格式"""
        try:
            parts = ip.split('.')
            if len(parts) != 4:
                return False
            for part in parts:
                if not 0 <= int(part) <= 255:
                    return False
            # 排除私有IP
            first_octet = int(parts[0])
            second_octet = int(parts[1])
            if (first_octet == 10 or 
                (first_octet == 172 and 16 <= second_octet <= 31) or
                (first_octet == 192 and second_octet == 168) or
                first_octet == 169):
                return False
            return True
        except (ValueError, AttributeError):
            return False
    
    def get_current_wan_ip(self) -> Optional[str]:
        """获取当前WAN IP"""
        # 优先从RouterOS获取
        wan_ip = self.get_wan_ip_from_routeros()
        
        # 如果RouterOS获取失败，使用公共服务
        if wan_ip is None:
            wan_ip = self.get_wan_ip_from_public_services()
        
        if wan_ip:
            logger.debug(f"当前WAN IP: {wan_ip}")
        else:
            logger.error("无法获取WAN IP")
        
        return wan_ip
    
    def update_livekit_config(self, new_ip: str) -> bool:
        """更新LiveKit配置文件中的node_ip"""
        try:
            if not os.path.exists(self.livekit_config_path):
                logger.error(f"LiveKit配置文件不存在: {self.livekit_config_path}")
                return False
            
            # 读取当前配置
            with open(self.livekit_config_path, 'r') as f:
                config = yaml.safe_load(f)
            
            # 检查是否需要更新
            current_node_ip = config.get('rtc', {}).get('node_ip', '')
            if current_node_ip == new_ip:
                logger.debug("LiveKit配置中的node_ip无需更新")
                return True
            
            # 更新node_ip
            if 'rtc' not in config:
                config['rtc'] = {}
            config['rtc']['node_ip'] = new_ip
            
            # 备份原配置
            backup_path = f"{self.livekit_config_path}.backup.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
            subprocess.run(['cp', self.livekit_config_path, backup_path], check=True)
            
            # 写入新配置
            with open(self.livekit_config_path, 'w') as f:
                yaml.dump(config, f, default_flow_style=False)
            
            logger.info(f"LiveKit配置已更新: node_ip = {new_ip}")
            return True
            
        except Exception as e:
            logger.error(f"更新LiveKit配置失败: {e}")
            return False
    
    def update_cloudflare_dns(self, new_ip: str) -> bool:
        """更新Cloudflare DNS记录"""
        if not self.cloudflare_api_token or not self.domains:
            logger.debug("Cloudflare配置不完整，跳过DNS更新")
            return True
        
        headers = {
            'Authorization': f'Bearer {self.cloudflare_api_token}',
            'Content-Type': 'application/json'
        }
        
        success = True
        for domain in self.domains:
            domain = domain.strip()
            if not domain:
                continue
                
            try:
                # 获取Zone ID
                zone_name = '.'.join(domain.split('.')[-2:])  # 获取主域名
                zone_response = requests.get(
                    f'https://api.cloudflare.com/client/v4/zones?name={zone_name}',
                    headers=headers,
                    timeout=30
                )
                
                if zone_response.status_code != 200:
                    logger.error(f"获取Zone ID失败: {domain} - {zone_response.text}")
                    success = False
                    continue
                
                zones = zone_response.json().get('result', [])
                if not zones:
                    logger.error(f"未找到Zone: {zone_name}")
                    success = False
                    continue
                
                zone_id = zones[0]['id']
                
                # 获取DNS记录
                records_response = requests.get(
                    f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={domain}&type=A',
                    headers=headers,
                    timeout=30
                )
                
                if records_response.status_code != 200:
                    logger.error(f"获取DNS记录失败: {domain} - {records_response.text}")
                    success = False
                    continue
                
                records = records_response.json().get('result', [])
                
                if records:
                    # 更新现有记录
                    record_id = records[0]['id']
                    current_ip = records[0]['content']
                    
                    if current_ip == new_ip:
                        logger.debug(f"DNS记录无需更新: {domain}")
                        continue
                    
                    update_data = {
                        'type': 'A',
                        'name': domain,
                        'content': new_ip,
                        'ttl': 300
                    }
                    
                    update_response = requests.put(
                        f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}',
                        headers=headers,
                        json=update_data,
                        timeout=30
                    )
                    
                    if update_response.status_code == 200:
                        logger.info(f"DNS记录已更新: {domain} -> {new_ip}")
                    else:
                        logger.error(f"更新DNS记录失败: {domain} - {update_response.text}")
                        success = False
                else:
                    # 创建新记录
                    create_data = {
                        'type': 'A',
                        'name': domain,
                        'content': new_ip,
                        'ttl': 300
                    }
                    
                    create_response = requests.post(
                        f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records',
                        headers=headers,
                        json=create_data,
                        timeout=30
                    )
                    
                    if create_response.status_code == 200:
                        logger.info(f"DNS记录已创建: {domain} -> {new_ip}")
                    else:
                        logger.error(f"创建DNS记录失败: {domain} - {create_response.text}")
                        success = False
                
            except Exception as e:
                logger.error(f"更新Cloudflare DNS失败: {domain} - {e}")
                success = False
        
        return success
    
    def restart_livekit_service(self) -> bool:
        """重启LiveKit服务"""
        try:
            logger.info("重启LiveKit服务...")
            
            # 使用Docker Compose重启LiveKit服务
            cmd = [
                'docker-compose',
                '-f', self.docker_compose_path,
                'restart', 'livekit'
            ]
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60
            )
            
            if result.returncode == 0:
                logger.info("LiveKit服务重启成功")
                return True
            else:
                logger.error(f"LiveKit服务重启失败: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"重启LiveKit服务时出错: {e}")
            return False
    
    def wait_for_service_ready(self, max_wait: int = 60) -> bool:
        """等待LiveKit服务就绪"""
        logger.info("等待LiveKit服务就绪...")
        
        for i in range(max_wait):
            try:
                # 检查LiveKit健康状态
                result = subprocess.run(
                    ['docker', 'exec', 'element-livekit', 'wget', '-q', '--spider', 'http://localhost:7880/rtc'],
                    capture_output=True,
                    timeout=5
                )
                
                if result.returncode == 0:
                    logger.info(f"LiveKit服务已就绪 (等待时间: {i+1}秒)")
                    return True
                    
            except Exception:
                pass
            
            time.sleep(1)
        
        logger.warning(f"LiveKit服务在{max_wait}秒内未就绪")
        return False
    
    def check_and_update(self) -> bool:
        """检查WAN IP并更新配置"""
        try:
            current_ip = self.get_current_wan_ip()
            
            if current_ip is None:
                logger.error("无法获取当前WAN IP")
                return False
            
            # 检查IP是否变化
            if self.last_wan_ip == current_ip:
                logger.debug(f"WAN IP未变化: {current_ip}")
                self.last_check_time = datetime.now()
                return True
            
            logger.info(f"检测到WAN IP变化: {self.last_wan_ip} -> {current_ip}")
            
            # 更新LiveKit配置
            if not self.update_livekit_config(current_ip):
                logger.error("更新LiveKit配置失败")
                return False
            
            # 更新Cloudflare DNS
            if not self.update_cloudflare_dns(current_ip):
                logger.warning("更新Cloudflare DNS部分失败")
            
            # 重启LiveKit服务
            if not self.restart_livekit_service():
                logger.error("重启LiveKit服务失败")
                return False
            
            # 等待服务就绪
            if not self.wait_for_service_ready():
                logger.warning("LiveKit服务重启后未能及时就绪")
            
            # 更新记录
            self.last_wan_ip = current_ip
            self.last_check_time = datetime.now()
            
            logger.info(f"WAN IP更新完成: {current_ip}")
            return True
            
        except Exception as e:
            logger.error(f"检查和更新过程中出错: {e}")
            return False
    
    def run(self):
        """运行监控服务"""
        logger.info("启动WAN IP监控服务...")
        
        # 初始检查
        self.check_and_update()
        
        while True:
            try:
                time.sleep(self.check_interval * 60)  # 转换为秒
                self.check_and_update()
                
            except KeyboardInterrupt:
                logger.info("收到中断信号，正在停止服务...")
                break
            except Exception as e:
                logger.error(f"监控服务运行时出错: {e}")
                time.sleep(60)  # 出错时等待1分钟再继续

def main():
    """主函数"""
    if len(sys.argv) > 1:
        config_file = sys.argv[1]
    else:
        config_file = '/etc/wan-ip-monitor.conf'
    
    monitor = WANIPMonitor(config_file)
    
    try:
        monitor.run()
    except Exception as e:
        logger.error(f"监控服务启动失败: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
