# Matrix 服务器配置模板集合
# 用于生成各种部署场景的配置文件

# 基础配置模板
generate_base_config() {
    local domain="$1"
    local http_port="$2"
    local https_port="$3"
    local install_dir="$4"
    
    cat << EOF
# 基础配置
domain: "$domain"
serverName: "$domain"
httpPort: $http_port
httpsPort: $https_port
installDir: "$install_dir"

# 子域名配置
subdomains:
  matrix: "matrix.$domain"
  account: "account.$domain"
  mrtc: "mrtc.$domain"
  chat: "chat.$domain"

# 网络配置
network:
  externalAccess: true
  customPorts: true
  ispBlocked: true
EOF
}

# Synapse 配置模板
generate_synapse_config() {
    local domain="$1"
    local https_port="$2"
    local postgres_password="$3"
    local signing_key="$4"
    local macaroon_secret="$5"
    local registration_token="$6"
    local enable_federation="$7"
    local enable_registration="$8"
    
    cat << EOF
synapse:
  enabled: true
  serverName: "$domain"
  
  # 公网访问配置 - 明确指定端口
  publicBaseurl: "https://matrix.$domain:$https_port"
  
  # 数据库配置
  postgresql:
    enabled: true
    auth:
      password: "$postgres_password"
      database: "synapse"
      username: "synapse"
  
  # 安全配置
  signingKey: "$signing_key"
  macaroonSecretKey: "$macaroon_secret"
  
  # 联邦配置
  federation:
    enabled: $enable_federation
    port: 8448
    publicUrl: "https://$domain:$https_port"
  
  # 注册配置
  registration:
    enabled: $enable_registration
    registrationSharedSecret: "$registration_token"
  
  # Well-known 配置 - 关键：包含端口信息
  wellknown:
    enabled: true
    server:
      "m.server": "matrix.$domain:$https_port"
    client:
      "m.homeserver":
        "base_url": "https://matrix.$domain:$https_port"
      "m.identity_server":
        "base_url": "https://account.$domain:$https_port"
      "org.matrix.msc3575.proxy":
        "url": "https://account.$domain:$https_port"
  
  # 媒体存储配置
  media:
    maxUploadSize: "100M"
    maxImagePixels: "32M"
    maxSpiderSize: "10M"
  
  # 速率限制配置
  rateLimit:
    perSecond: 0.2
    burstCount: 10
  
  # 日志配置
  logging:
    level: "INFO"
    structured: true
EOF
}

# MAS 配置模板
generate_mas_config() {
    local domain="$1"
    local https_port="$2"
    local postgres_password="$3"
    local mas_secret_key="$4"
    local mas_encryption_key="$5"
    
    cat << EOF
mas:
  enabled: true
  
  # 公网访问配置
  publicUrl: "https://account.$domain:$https_port"
  
  config:
    # 密钥配置
    secrets:
      encryption: "$mas_encryption_key"
      keys:
        - kid: "default"
          key: "$mas_secret_key"
    
    # 数据库配置
    database:
      uri: "postgresql://synapse:$postgres_password@postgresql:5432/mas"
    
    # HTTP 配置
    http:
      listeners:
        - name: "web"
          resources:
            - name: "discovery"
            - name: "human"
            - name: "oauth"
            - name: "compat"
          binds:
            - address: "0.0.0.0:8080"
      # 公网访问配置 - 包含端口
      public_base: "https://account.$domain:$https_port"
      issuer: "https://account.$domain:$https_port"
    
    # 上游配置
    upstream:
      name: "synapse"
      oidc_discovery_url: "https://matrix.$domain:$https_port/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"
    
    # 客户端配置
    clients:
      - client_id: "01234567-89ab-cdef-0123-456789abcdef"
        client_auth_method: "client_secret_basic"
        client_secret: "$mas_secret_key"
EOF
}

# Element Web 配置模板
generate_element_web_config() {
    local domain="$1"
    local https_port="$2"
    
    cat << EOF
elementWeb:
  enabled: true
  
  # 公网访问配置
  publicUrl: "https://chat.$domain:$https_port"
  
  config:
    # 默认服务器配置
    default_server_config:
      "m.homeserver":
        "base_url": "https://matrix.$domain:$https_port"
        "server_name": "$domain"
      "m.identity_server":
        "base_url": "https://account.$domain:$https_port"
    
    # 集成管理器配置
    integrations_ui_url: "https://account.$domain:$https_port"
    integrations_rest_url: "https://account.$domain:$https_port"
    
    # Element Call 配置
    element_call:
      url: "https://mrtc.$domain:$https_port"
      use_exclusively: false
    
    # 功能配置
    features:
      feature_video_rooms: true
      feature_element_call_video_rooms: true
      feature_group_calls: true
    
    # 界面配置
    brand: "Matrix Chat"
    welcome_user_id: "@admin:$domain"
    
    # 安全配置
    disable_guests: true
    disable_login_language_selector: false
    disable_3pid_login: false
EOF
}

# Matrix RTC 配置模板
generate_matrix_rtc_config() {
    local domain="$1"
    local https_port="$2"
    local webrtc_tcp_port="$3"
    local webrtc_udp_port="$4"
    local external_ip="$5"
    
    cat << EOF
matrixRtc:
  enabled: true
  
  # 公网访问配置
  publicUrl: "https://mrtc.$domain:$https_port"
  
  # WebRTC 配置
  webrtc:
    tcp_port: $webrtc_tcp_port
    udp_port: $webrtc_udp_port
    external_ip: "$external_ip"
    
    # STUN/TURN 配置
    stun_servers:
      - "stun:stun.l.google.com:19302"
      - "stun:stun1.l.google.com:19302"
    
    # 媒体配置
    media:
      max_participants: 50
      video_codec: "VP8"
      audio_codec: "OPUS"
      bitrate_limit: "2000000"  # 2Mbps
  
  # 房间配置
  rooms:
    default_power_level: 50
    guest_access: "forbidden"
    history_visibility: "invited"
EOF
}

# Ingress 配置模板
generate_ingress_config() {
    local domain="$1"
    local https_port="$2"
    local namespace="$3"
    
    cat << EOF
# 自定义 Ingress 配置
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: matrix-ingress
  namespace: $namespace
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: "letsencrypt"
    # 强制使用自定义端口
    traefik.ingress.kubernetes.io/router.rule: "Host(\`$domain\`) || Host(\`matrix.$domain\`) || Host(\`account.$domain\`) || Host(\`mrtc.$domain\`) || Host(\`chat.$domain\`)"
    # HTTPS 重定向中间件
    traefik.ingress.kubernetes.io/router.middlewares: "default-redirect-https@kubernetescrd"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - "$domain"
        - "matrix.$domain"
        - "account.$domain"
        - "mrtc.$domain"
        - "chat.$domain"
      secretName: matrix-tls
  rules:
    - host: "$domain"
      http:
        paths:
          - path: /.well-known/matrix
            pathType: Prefix
            backend:
              service:
                name: matrix-synapse
                port:
                  number: 8008
    - host: "matrix.$domain"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-synapse
                port:
                  number: 8008
    - host: "account.$domain"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-mas
                port:
                  number: 8080
    - host: "mrtc.$domain"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-rtc
                port:
                  number: 8080
    - host: "chat.$domain"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-element-web
                port:
                  number: 8080
---
# HTTPS 重定向中间件
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: default
spec:
  redirectScheme:
    scheme: https
    port: "$https_port"
    permanent: true
EOF
}

# Traefik 配置模板
generate_traefik_config() {
    local http_port="$1"
    local https_port="$2"
    local external_ip="$3"
    local cert_email="$4"
    local cloudflare_token="$5"
    
    cat << EOF
# Traefik 自定义端口配置
apiVersion: v1
kind: Namespace
metadata:
  name: traefik-system
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: traefik
  namespace: kube-system
spec:
  chart: traefik
  repo: https://traefik.github.io/charts
  targetNamespace: traefik-system
  valuesContent: |-
    # 端口配置 - 使用自定义端口
    ports:
      web:
        port: $http_port
        exposedPort: $http_port
        nodePort: 30080
      websecure:
        port: $https_port
        exposedPort: $https_port
        nodePort: 30443
    
    # 服务配置
    service:
      type: NodePort
      spec:
        externalIPs:
          - "$external_ip"
    
    # Ingress 路由配置
    ingressRoute:
      dashboard:
        enabled: false
    
    # 提供商配置
    providers:
      kubernetesCRD:
        enabled: true
      kubernetesIngress:
        enabled: true
    
    # 证书解析器配置
    certificatesResolvers:
      letsencrypt:
        acme:
          email: $cert_email
          storage: /data/acme.json
          dnsChallenge:
            provider: cloudflare
            resolvers:
              - "1.1.1.1:53"
              - "8.8.8.8:53"
    
    # 环境变量
    env:
      - name: CF_API_TOKEN
        value: "$cloudflare_token"
    
    # 日志配置
    logs:
      general:
        level: INFO
      access:
        enabled: true
    
    # 指标配置
    metrics:
      prometheus:
        enabled: true
EOF
}

# 生成完整的部署配置
generate_complete_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "配置文件不存在: $config_file"
        return 1
    fi
    
    source "$config_file"
    
    local output_dir="$(dirname "$config_file")/generated"
    mkdir -p "$output_dir"
    
    # 生成各个组件的配置
    generate_base_config "$DOMAIN" "$HTTP_PORT" "$HTTPS_PORT" "$INSTALL_DIR" > "$output_dir/base-config.yaml"
    
    generate_synapse_config "$DOMAIN" "$HTTPS_PORT" "$POSTGRES_PASSWORD" "$SYNAPSE_SIGNING_KEY" "$SYNAPSE_MACAROON_SECRET" "$REGISTRATION_TOKEN" "$ENABLE_FEDERATION" "$ENABLE_REGISTRATION" > "$output_dir/synapse-config.yaml"
    
    generate_mas_config "$DOMAIN" "$HTTPS_PORT" "$POSTGRES_PASSWORD" "$MAS_SECRET_KEY" "$MAS_ENCRYPTION_KEY" > "$output_dir/mas-config.yaml"
    
    generate_element_web_config "$DOMAIN" "$HTTPS_PORT" > "$output_dir/element-web-config.yaml"
    
    generate_matrix_rtc_config "$DOMAIN" "$HTTPS_PORT" "$WEBRTC_TCP_PORT" "$WEBRTC_UDP_PORT" "$(get_external_ip)" > "$output_dir/matrix-rtc-config.yaml"
    
    generate_ingress_config "$DOMAIN" "$HTTPS_PORT" "$NAMESPACE" > "$output_dir/ingress-config.yaml"
    
    generate_traefik_config "$HTTP_PORT" "$HTTPS_PORT" "$(get_external_ip)" "$CERT_EMAIL" "$CLOUDFLARE_TOKEN" > "$output_dir/traefik-config.yaml"
    
    echo "配置文件已生成到: $output_dir"
}

# 获取外部IP的辅助函数
get_external_ip() {
    local ip
    
    # 尝试从域名解析获取
    if [[ -n "${DOMAIN:-}" ]]; then
        ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null || dig +short "$DOMAIN" @1.1.1.1 2>/dev/null)
    fi
    
    # 备用方法
    if [[ -z "$ip" ]]; then
        ip=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "127.0.0.1")
    fi
    
    echo "${ip:-127.0.0.1}"
}

