#!/bin/bash
set -e

echo "🚀 Installation de Quizzouille sur Hetzner"
echo "=========================================="

# ⚠️ CONFIGUREZ CES VARIABLES AVANT D'EXÉCUTER
GITHUB_REPO="git@github.com:alexandrepetrillo/quizzouille.git"
DOMAIN="quizzouille.fun"  # Laissez vide si pas de domaine, sinon "quizzouille.fun"
EMAIL="alexandre.petrillo@gmail.com"   # Votre email pour Let's Encrypt (requis si DOMAIN est défini)

# Génération automatique des secrets
DB_PASSWORD="$(openssl rand -hex 16)"
JWT_SECRET="$(openssl rand -hex 24)"
JWT_REFRESH_SECRET="$(openssl rand -hex 24)"

# 1. Mise à jour système
echo "📦 Mise à jour du système..."
apt update && apt upgrade -y

# 2. Installation Node.js 20
echo "📦 Installation Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# 3. Installation PostgreSQL 15
echo "📦 Installation PostgreSQL..."
apt install -y postgresql postgresql-contrib
systemctl start postgresql
systemctl enable postgresql

# 4. Installation Redis
echo "📦 Installation Redis..."
apt install -y redis-server

# Créer le groupe redis si inexistant
if ! getent group redis > /dev/null 2>&1; then
    groupadd -r redis
fi

# Créer l'utilisateur redis si inexistant
if ! id -u redis > /dev/null 2>&1; then
    useradd -r -s /bin/false -g redis redis
fi

# Créer les répertoires nécessaires
mkdir -p /var/lib/redis
mkdir -p /var/log/redis
chown -R redis:redis /var/lib/redis
chown -R redis:redis /var/log/redis
chmod 750 /var/lib/redis
chmod 750 /var/log/redis

# Configurer Redis pour utiliser systemd
sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf

# Démarrer Redis
systemctl daemon-reload

systemctl start redis-server
systemctl enable redis-server

# Vérifier que Redis fonctionne
if ! systemctl is-active --quiet redis-server; then
    echo "⚠️  Redis n'a pas démarré correctement, tentative de fix..."
    systemctl restart redis-server
    sleep 2
fi

# 5. Installation Nginx
# 5. Installation Nginx
echo "📦 Installation Nginx..."

# Créer les groupes d'abord
if ! getent group adm > /dev/null 2>&1; then
    groupadd -r adm
fi

if ! getent group www-data > /dev/null 2>&1; then
    groupadd -r www-data
fi

# Puis créer l'utilisateur www-data
if ! id -u www-data > /dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /var/www -g www-data www-data
fi

# Ajouter www-data au groupe adm
usermod -a -G adm www-data 2>/dev/null || true

# Installer Nginx
echo "Installation de Nginx..."
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || true
apt-get install -f -y || true
apt install -y nginx

# Créer les répertoires
mkdir -p /var/log/nginx
mkdir -p /var/www/html
chown -R www-data:adm /var/log/nginx
chown -R www-data:www-data /var/www

# Démarrer Nginx
systemctl daemon-reload
systemctl start nginx
systemctl enable nginx

# Vérifier
sleep 2
if ! systemctl is-active --quiet nginx; then
    echo "⚠️ Nginx n'a pas démarré, tentative de fix..."
    systemctl restart nginx
fi

# 6. Installation PM2, TypeScript et tsx
echo "📦 Installation PM2, TypeScript et tsx..."
npm install -g pm2 typescript tsx

# 7. Installation Certbot (SSL)
echo "📦 Installation Certbot..."
apt install -y certbot python3-certbot-nginx

# 8. Installation Git
apt install -y git

# 9. Configuration PostgreSQL
echo "🗄️ Configuration PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE DATABASE quizzouille_db;
CREATE USER quizzouille WITH ENCRYPTED PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE quizzouille_db TO quizzouille;
ALTER DATABASE quizzouille_db OWNER TO quizzouille;
\c quizzouille_db
GRANT ALL ON SCHEMA public TO quizzouille;
\q
EOF

# 10. Clone du projet
echo "📥 Clone du projet depuis GitHub..."
cd /var
rm -rf quizzouille 2>/dev/null || true
git clone $GITHUB_REPO quizzouille
cd quizzouille

# 11. Configuration backend
echo "⚙️ Configuration backend..."
cd /var/quizzouille/backend

# Déterminer l'URL CORS
if [ ! -z "$DOMAIN" ]; then
    CORS_URL="http://$DOMAIN"
else
    CORS_URL="http://$(curl -s ifconfig.me)"
fi

cat > .env <<EOF
# Database
DATABASE_URL="postgresql://quizzouille:$DB_PASSWORD@localhost:5432/quizzouille_db?schema=public"

# Redis
REDIS_URL="redis://localhost:6379"

# JWT
JWT_SECRET=$JWT_SECRET
JWT_REFRESH_SECRET=$JWT_REFRESH_SECRET
JWT_EXPIRES_IN=15m
JWT_REFRESH_EXPIRES_IN=7d

# Server
NODE_ENV=production
PORT=3000
HOST=localhost

# CORS
CORS_ORIGIN=$CORS_URL
EOF

# Installation dépendances backend (avec devDependencies pour le build TypeScript)
npm install

# Générer Prisma Client
npx prisma generate

# Build TypeScript
npm run build

# Exécuter migrations
npx prisma migrate deploy

# Seed database
npm run prisma:seed || echo "⚠️ Seed échoué (normal si déjà exécuté)"

# 12. Build frontend
echo "🎨 Build du frontend..."
cd /var/quizzouille/frontend

# Déterminer l'URL de l'API
if [ ! -z "$DOMAIN" ]; then
    API_URL="http://$DOMAIN"
else
    API_URL="http://$(curl -s ifconfig.me)"
fi

cat > .env.production <<EOF
VITE_API_URL=$API_URL
VITE_WS_URL=$API_URL
EOF

npm install
npm run build

# 13. Configuration Nginx
echo "🌐 Configuration Nginx..."

# Déterminer le server_name basé sur la présence d'un domaine
if [ -z "$DOMAIN" ]; then
    SERVER_NAME="_"
else
    SERVER_NAME="$DOMAIN www.$DOMAIN"
fi

cat > /etc/nginx/sites-available/quizzouille <<NGINX_EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    client_max_body_size 10M;

    # Frontend
    location / {
        root /var/quizzouille/frontend/dist;
        try_files \$uri \$uri/ /index.html;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }

    # Backend API
    location /api {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # WebSocket
    location /socket.io {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }

    # Compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
}
NGINX_EOF

# Activer le site
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/quizzouille /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Configuration SSL si un domaine est fourni
if [ ! -z "$DOMAIN" ] && [ ! -z "$EMAIL" ]; then
    echo "🔒 Configuration HTTPS avec Let's Encrypt..."

    # Vérifier que le DNS pointe vers ce serveur
    PUBLIC_IP=$(curl -s ifconfig.me)
    DNS_IP=$(dig +short $DOMAIN @8.8.8.8 | head -n1)

    if [ "$PUBLIC_IP" = "$DNS_IP" ]; then
        echo "✅ DNS correctement configuré, installation du certificat SSL..."

        # Obtenir le certificat SSL
        if certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect; then
            echo "✅ Certificat SSL installé avec succès"
            # Mettre à jour les URLs pour HTTPS
            PROTOCOL="https"
        else
            echo "⚠️  Erreur lors de l'installation du certificat SSL"
            echo "   Vous pourrez le configurer manuellement plus tard"
            PROTOCOL="http"
        fi
    else
        echo "⚠️  Le DNS ne pointe pas encore vers ce serveur"
        echo "   IP serveur: $PUBLIC_IP"
        echo "   IP DNS: $DNS_IP"
        echo "   Configurez le SSL manuellement après la propagation DNS"
        PROTOCOL="http"
    fi
else
    PROTOCOL="http"
    PUBLIC_IP=$(curl -s ifconfig.me)
fi

# 14. Démarrage backend avec PM2
echo "🚀 Démarrage du backend..."
cd /var/quizzouille/backend
pm2 delete quizzouille-backend 2>/dev/null || true
pm2 start npm --name quizzouille-backend -- start
pm2 save

# Configurer PM2 pour démarrer au boot (sans pipe qui cause des problèmes)
env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u root --hp /root
systemctl enable pm2-root

# Si HTTPS a été configuré, mettre à jour les URLs
if [ ! -z "$DOMAIN" ] && [ ! -z "$EMAIL" ] && [ "$PROTOCOL" = "https" ]; then
    echo "🔄 Mise à jour des URLs pour HTTPS..."

    # Mettre à jour backend CORS
    sed -i "s|CORS_ORIGIN=http://|CORS_ORIGIN=https://|g" /var/quizzouille/backend/.env

    # Mettre à jour frontend
    sed -i "s|VITE_API_URL=http://|VITE_API_URL=https://|g" /var/quizzouille/frontend/.env.production
    sed -i "s|VITE_WS_URL=http://|VITE_WS_URL=https://|g" /var/quizzouille/frontend/.env.production

    # Rebuild frontend
    cd /var/quizzouille/frontend
    npm run build

    # Redémarrer backend
    cd /var/quizzouille/backend
    pm2 restart quizzouille-backend

    # Recharger Nginx
    systemctl reload nginx
fi

# 15. Créer script de mise à jour
cat > /root/deploy.sh <<'DEPLOY_EOF'
#!/bin/bash
set -e
echo "🔄 Déploiement nouvelle version..."
cd /var/quizzouille
git pull origin main
cd backend
npm install
npx prisma generate
npm run build
npx prisma migrate deploy
pm2 restart quizzouille-backend
cd ../frontend
npm install
npm run build
nginx -t && systemctl reload nginx
echo "✅ Déploiement terminé !"
DEPLOY_EOF

chmod +x /root/deploy.sh

# 16. Créer script de backup
cat > /root/backup-db.sh <<'BACKUP_EOF'
#!/bin/bash
BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
sudo -u postgres pg_dump quizzouille_db > $BACKUP_DIR/db_$DATE.sql
ls -t $BACKUP_DIR/db_*.sql | tail -n +8 | xargs rm -f
echo "✅ Backup créé : db_$DATE.sql"
BACKUP_EOF

chmod +x /root/backup-db.sh

# Ajouter backup au cron (tous les jours à 3h)
(crontab -l 2>/dev/null; echo "0 3 * * * /root/backup-db.sh") | crontab -

# 17. Affichage des informations
PUBLIC_IP=$(curl -s ifconfig.me)
echo ""
echo "✅ ✅ ✅ Installation terminée ! ✅ ✅ ✅"
echo "=========================================="
echo ""
echo "🌐 Accès à l'application :"
if [ ! -z "$DOMAIN" ] && [ "$PROTOCOL" = "https" ]; then
    echo "   https://$DOMAIN"
    echo "   https://www.$DOMAIN"
else
    if [ ! -z "$DOMAIN" ]; then
        echo "   http://$DOMAIN"
        echo "   http://www.$DOMAIN"
    else
        echo "   http://$PUBLIC_IP"
    fi
fi
echo ""
echo "📝 Credentials de connexion démo :"
echo "   Email: demo@quizzouille.com"
echo "   Mot de passe: demo123"
echo ""
echo "🗄️ Base de données :"
echo "   Database: quizzouille_db"
echo "   User: quizzouille"
echo "   Password: $DB_PASSWORD"
echo ""
echo "🔐 Secrets JWT générés automatiquement"
echo ""
echo "📋 Commandes utiles :"
echo "   pm2 status                    # État du backend"
echo "   pm2 logs quizzouille-backend  # Voir les logs"
echo "   /root/deploy.sh               # Déployer nouvelle version"
echo "   /root/backup-db.sh            # Backup manuel"
echo ""

if [ ! -z "$DOMAIN" ]; then
    if [ "$PROTOCOL" = "https" ]; then
        echo "✅ HTTPS configuré avec succès !"
        echo "   Certificat SSL installé et actif"
        echo "   Renouvellement automatique activé"
    else
        echo "🔒 Configuration HTTPS manuelle nécessaire :"
        echo "   1. Pointer $DOMAIN vers $PUBLIC_IP chez votre registrar"
        echo "   2. Attendre propagation DNS (5-30 min)"
        echo "   3. Télécharger le script de configuration :"
        echo "      wget https://raw.githubusercontent.com/VOTRE_REPO/main/configure-https.sh"
        echo "   4. Éditer l'EMAIL dans le script"
        echo "   5. Exécuter : chmod +x configure-https.sh && ./configure-https.sh"
        echo ""
        echo "   OU manuellement :"
        echo "      certbot --nginx -d $DOMAIN -d www.$DOMAIN --email $EMAIL"
        echo "      Puis modifier /var/quizzouille/backend/.env (CORS_ORIGIN)"
        echo "      Et /var/quizzouille/frontend/.env.production (URLs)"
        echo "      Puis : /root/deploy.sh"
    fi
fi

echo ""
echo "🎉 Quizzouille est maintenant en ligne !"
echo "=========================================="
