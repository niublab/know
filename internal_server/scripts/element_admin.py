#!/usr/bin/env python3
"""
Element ESS Admin管理工具 v2.1
提供用户管理、服务管理、系统监控等功能
"""

import os
import sys
import json
import yaml
import sqlite3
import hashlib
import secrets
import subprocess
import argparse
import datetime
from pathlib import Path
from flask import Flask, request, jsonify, render_template_string, session, redirect, url_for
from werkzeug.security import generate_password_hash, check_password_hash
import jwt
import requests
from functools import wraps

# Flask应用配置
app = Flask(__name__)
app.secret_key = os.environ.get('ADMIN_JWT_SECRET', secrets.token_hex(32))

# 配置常量
ADMIN_DB_PATH = os.environ.get('ADMIN_DB_PATH', '/opt/element-ess/data/admin/admin.db')
SYNAPSE_ADMIN_API = 'http://synapse:8008/_synapse/admin/v1'
DOCKER_COMPOSE_PATH = os.environ.get('DOCKER_COMPOSE_PATH', '/opt/element-ess/docker-compose.yml')
CONFIG_DIR = '/opt/element-ess/config'

class ElementAdmin:
    """Element ESS管理类"""
    
    def __init__(self):
        self.init_database()
        self.synapse_access_token = None
        
    def init_database(self):
        """初始化管理数据库"""
        os.makedirs(os.path.dirname(ADMIN_DB_PATH), exist_ok=True)
        
        conn = sqlite3.connect(ADMIN_DB_PATH)
        cursor = conn.cursor()
        
        # 创建管理员表
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS admins (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_login TIMESTAMP
        )
        ''')
        
        # 创建操作日志表
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS operation_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            admin_username TEXT NOT NULL,
            operation TEXT NOT NULL,
            details TEXT,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ip_address TEXT
        )
        ''')
        
        # 创建默认管理员账户
        admin_username = os.environ.get('ADMIN_USERNAME', 'admin')
        admin_password = os.environ.get('ADMIN_PASSWORD', 'admin123')
        
        cursor.execute('SELECT COUNT(*) FROM admins WHERE username = ?', (admin_username,))
        if cursor.fetchone()[0] == 0:
            password_hash = generate_password_hash(admin_password)
            cursor.execute(
                'INSERT INTO admins (username, password_hash) VALUES (?, ?)',
                (admin_username, password_hash)
            )
            print(f"创建默认管理员账户: {admin_username}")
        
        conn.commit()
        conn.close()
    
    def authenticate_admin(self, username, password):
        """验证管理员身份"""
        conn = sqlite3.connect(ADMIN_DB_PATH)
        cursor = conn.cursor()
        
        cursor.execute('SELECT password_hash FROM admins WHERE username = ?', (username,))
        result = cursor.fetchone()
        
        if result and check_password_hash(result[0], password):
            # 更新最后登录时间
            cursor.execute(
                'UPDATE admins SET last_login = CURRENT_TIMESTAMP WHERE username = ?',
                (username,)
            )
            conn.commit()
            conn.close()
            return True
        
        conn.close()
        return False
    
    def log_operation(self, admin_username, operation, details=None, ip_address=None):
        """记录操作日志"""
        conn = sqlite3.connect(ADMIN_DB_PATH)
        cursor = conn.cursor()
        
        cursor.execute(
            'INSERT INTO operation_logs (admin_username, operation, details, ip_address) VALUES (?, ?, ?, ?)',
            (admin_username, operation, details, ip_address)
        )
        
        conn.commit()
        conn.close()
    
    def get_synapse_admin_token(self):
        """获取Synapse管理员访问令牌"""
        if self.synapse_access_token:
            return self.synapse_access_token
            
        # 从配置文件读取管理员用户信息
        homeserver_config = f"{CONFIG_DIR}/synapse/homeserver.yaml"
        if os.path.exists(homeserver_config):
            with open(homeserver_config, 'r') as f:
                config = yaml.safe_load(f)
                # 这里应该实现获取管理员令牌的逻辑
                # 可能需要创建一个管理员用户并生成访问令牌
        
        return None
    
    def create_matrix_user(self, username, password, admin=False):
        """创建Matrix用户"""
        try:
            # 使用Synapse Admin API创建用户
            url = f"{SYNAPSE_ADMIN_API}/users/@{username}:{os.environ.get('MATRIX_SERVER_NAME')}"
            headers = {
                'Authorization': f'Bearer {self.get_synapse_admin_token()}',
                'Content-Type': 'application/json'
            }
            data = {
                'password': password,
                'admin': admin,
                'displayname': username
            }
            
            response = requests.put(url, headers=headers, json=data)
            return response.status_code == 201 or response.status_code == 200
            
        except Exception as e:
            print(f"创建用户失败: {e}")
            return False
    
    def get_matrix_users(self):
        """获取Matrix用户列表"""
        try:
            url = f"{SYNAPSE_ADMIN_API}/users"
            headers = {
                'Authorization': f'Bearer {self.get_synapse_admin_token()}',
                'Content-Type': 'application/json'
            }
            
            response = requests.get(url, headers=headers)
            if response.status_code == 200:
                return response.json().get('users', [])
            
        except Exception as e:
            print(f"获取用户列表失败: {e}")
            
        return []
    
    def get_service_status(self):
        """获取服务状态"""
        try:
            result = subprocess.run(
                ['docker-compose', '-f', DOCKER_COMPOSE_PATH, 'ps', '--format', 'json'],
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0:
                services = []
                for line in result.stdout.strip().split('\n'):
                    if line:
                        service_info = json.loads(line)
                        services.append({
                            'name': service_info.get('Service'),
                            'status': service_info.get('State'),
                            'health': service_info.get('Health', 'N/A')
                        })
                return services
            
        except Exception as e:
            print(f"获取服务状态失败: {e}")
            
        return []
    
    def restart_service(self, service_name):
        """重启服务"""
        try:
            result = subprocess.run(
                ['docker-compose', '-f', DOCKER_COMPOSE_PATH, 'restart', service_name],
                capture_output=True,
                text=True
            )
            return result.returncode == 0
        except Exception as e:
            print(f"重启服务失败: {e}")
            return False
    
    def get_system_stats(self):
        """获取系统统计信息"""
        stats = {}
        
        try:
            # CPU使用率
            result = subprocess.run(['top', '-bn1'], capture_output=True, text=True)
            for line in result.stdout.split('\n'):
                if 'Cpu(s)' in line:
                    stats['cpu_usage'] = line.split()[1]
                    break
            
            # 内存使用
            result = subprocess.run(['free', '-h'], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            if len(lines) > 1:
                mem_line = lines[1].split()
                stats['memory_total'] = mem_line[1]
                stats['memory_used'] = mem_line[2]
                stats['memory_free'] = mem_line[3]
            
            # 磁盘使用
            result = subprocess.run(['df', '-h', '/'], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            if len(lines) > 1:
                disk_line = lines[1].split()
                stats['disk_total'] = disk_line[1]
                stats['disk_used'] = disk_line[2]
                stats['disk_free'] = disk_line[3]
                stats['disk_usage_percent'] = disk_line[4]
                
        except Exception as e:
            print(f"获取系统统计失败: {e}")
            
        return stats

# 全局管理器实例
admin_manager = ElementAdmin()

# 装饰器：需要登录
def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'admin_username' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

# Web界面模板
LOGIN_TEMPLATE = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Element ESS 管理后台</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f5f5f5; margin: 0; padding: 50px; }
        .login-container { max-width: 400px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .login-header { text-align: center; margin-bottom: 30px; color: #333; }
        .form-group { margin-bottom: 20px; }
        label { display: block; margin-bottom: 5px; color: #555; }
        input { width: 100%; padding: 12px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; }
        .btn { width: 100%; padding: 12px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        .btn:hover { background: #0056b3; }
        .error { color: red; margin-top: 10px; }
    </style>
</head>
<body>
    <div class="login-container">
        <h2 class="login-header">Element ESS 管理后台</h2>
        <form method="POST">
            <div class="form-group">
                <label for="username">用户名:</label>
                <input type="text" id="username" name="username" required>
            </div>
            <div class="form-group">
                <label for="password">密码:</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit" class="btn">登录</button>
            {% if error %}
            <div class="error">{{ error }}</div>
            {% endif %}
        </form>
    </div>
</body>
</html>
'''

DASHBOARD_TEMPLATE = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Element ESS 管理后台</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }
        .header { background: #007bff; color: white; padding: 1rem; display: flex; justify-content: space-between; align-items: center; }
        .nav { background: #343a40; color: white; padding: 1rem; }
        .nav a { color: white; text-decoration: none; margin-right: 20px; padding: 8px 16px; border-radius: 4px; }
        .nav a:hover { background: #495057; }
        .nav a.active { background: #007bff; }
        .container { padding: 20px; }
        .card { background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; }
        .card-header { background: #f8f9fa; padding: 15px; border-bottom: 1px solid #dee2e6; font-weight: bold; }
        .card-body { padding: 20px; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; }
        .stat-card { text-align: center; padding: 20px; background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .stat-value { font-size: 2em; font-weight: bold; color: #007bff; }
        .stat-label { color: #666; margin-top: 5px; }
        .btn { padding: 8px 16px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; text-decoration: none; display: inline-block; }
        .btn:hover { background: #0056b3; }
        .btn-danger { background: #dc3545; }
        .btn-danger:hover { background: #c82333; }
        .btn-success { background: #28a745; }
        .btn-success:hover { background: #218838; }
        .table { width: 100%; border-collapse: collapse; }
        .table th, .table td { padding: 12px; text-align: left; border-bottom: 1px solid #dee2e6; }
        .table th { background: #f8f9fa; }
        .status-running { color: #28a745; }
        .status-stopped { color: #dc3545; }
        .status-unhealthy { color: #ffc107; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Element ESS 管理后台</h1>
        <div>
            <span>欢迎, {{ session.admin_username }}</span>
            <a href="{{ url_for('logout') }}" class="btn" style="margin-left: 10px;">退出</a>
        </div>
    </div>
    
    <div class="nav">
        <a href="{{ url_for('dashboard') }}" class="active">仪表板</a>
        <a href="{{ url_for('users') }}">用户管理</a>
        <a href="{{ url_for('services') }}">服务管理</a>
        <a href="{{ url_for('logs') }}">操作日志</a>
    </div>
    
    <div class="container">
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-value">{{ stats.memory_used or 'N/A' }}</div>
                <div class="stat-label">内存使用</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">{{ stats.cpu_usage or 'N/A' }}</div>
                <div class="stat-label">CPU使用率</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">{{ stats.disk_usage_percent or 'N/A' }}</div>
                <div class="stat-label">磁盘使用率</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">{{ services|length }}</div>
                <div class="stat-label">运行服务</div>
            </div>
        </div>
        
        <div class="card">
            <div class="card-header">服务状态</div>
            <div class="card-body">
                <table class="table">
                    <thead>
                        <tr>
                            <th>服务名称</th>
                            <th>状态</th>
                            <th>健康状态</th>
                            <th>操作</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for service in services %}
                        <tr>
                            <td>{{ service.name }}</td>
                            <td class="status-{{ 'running' if service.status == 'running' else 'stopped' }}">
                                {{ service.status }}
                            </td>
                            <td class="status-{{ 'running' if service.health == 'healthy' else 'unhealthy' }}">
                                {{ service.health }}
                            </td>
                            <td>
                                <a href="{{ url_for('restart_service', service_name=service.name) }}" class="btn btn-success">重启</a>
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>
</body>
</html>
'''

# 路由定义
@app.route('/')
def index():
    if 'admin_username' in session:
        return redirect(url_for('dashboard'))
    return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        
        if admin_manager.authenticate_admin(username, password):
            session['admin_username'] = username
            admin_manager.log_operation(
                username, 
                '登录成功', 
                ip_address=request.remote_addr
            )
            return redirect(url_for('dashboard'))
        else:
            return render_template_string(LOGIN_TEMPLATE, error='用户名或密码错误')
    
    return render_template_string(LOGIN_TEMPLATE)

@app.route('/logout')
def logout():
    if 'admin_username' in session:
        admin_manager.log_operation(
            session['admin_username'], 
            '退出登录', 
            ip_address=request.remote_addr
        )
        session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    stats = admin_manager.get_system_stats()
    services = admin_manager.get_service_status()
    
    return render_template_string(
        DASHBOARD_TEMPLATE,
        stats=stats,
        services=services,
        session=session
    )

@app.route('/users')
@login_required
def users():
    # 用户管理页面（待实现）
    return jsonify({'message': '用户管理功能正在开发中'})

@app.route('/services')
@login_required
def services():
    # 服务管理页面（待实现）
    return jsonify({'message': '服务管理功能正在开发中'})

@app.route('/logs')
@login_required
def logs():
    # 操作日志页面（待实现）
    return jsonify({'message': '操作日志功能正在开发中'})

@app.route('/restart_service/<service_name>')
@login_required
def restart_service(service_name):
    success = admin_manager.restart_service(service_name)
    admin_manager.log_operation(
        session['admin_username'],
        f'重启服务: {service_name}',
        f'结果: {"成功" if success else "失败"}',
        request.remote_addr
    )
    return redirect(url_for('dashboard'))

# API接口
@app.route('/api/stats')
@login_required
def api_stats():
    return jsonify(admin_manager.get_system_stats())

@app.route('/api/services')
@login_required
def api_services():
    return jsonify(admin_manager.get_service_status())

def main():
    """主函数"""
    parser = argparse.ArgumentParser(description='Element ESS Admin管理工具')
    parser.add_argument('--port', type=int, default=8888, help='监听端口')
    parser.add_argument('--host', default='0.0.0.0', help='监听地址')
    parser.add_argument('--debug', action='store_true', help='调试模式')
    
    args = parser.parse_args()
    
    print(f"启动Element ESS Admin管理工具...")
    print(f"访问地址: http://localhost:{args.port}")
    print(f"默认账户: admin / admin123")
    
    app.run(host=args.host, port=args.port, debug=args.debug)

if __name__ == '__main__':
    main()
