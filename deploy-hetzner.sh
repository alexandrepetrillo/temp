#!/bin/bash
set -e

echo "🚀 Installation de Quizzouille sur Hetzner"
echo "=========================================="

# ⚠️ CONFIGUREZ CES VARIABLES AVANT D'EXÉCUTER
GITHUB_REPO="git@github.com::alexandrepetrillo/quizzouille"
DOMAIN=""  # Laissez vide si pas de domaine, sinon "exemple.com"

# Génération automatique des secrets
DB_PASSWORD="$(openssl rand -base64 32)"
JWT_SECRET="$(openssl rand -base64 48)"
JWT_REFRESH_SECRET="$(openssl rand -base64 48)"

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
systemctl start redis
systemctl enable redis

# 5. Installation Nginx
echo "📦 Installation Nginx..."
apt install -y nginx
systemctl start nginx
systemctl enable nginx

# 6. Installation PM2
echo "📦 Installation PM2..."
npm install -g pm2

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
CORS_ORIGIN=http://$(curl -s ifconfig.me)
EOF

# Installation dépendances backend
npm install --production

# Générer Prisma Client
npx prisma generate

# Exécuter migrations
npx prisma migrate deploy

# Seed database
npm run prisma:seed || echo "⚠️ Seed échoué (normal si déjà exécuté)"

# 12. Build frontend
echo "🎨 Build du frontend..."
cd /var/quizzouille/frontend

cat > .env.production <<EOF
VITE_API_URL=http://$(curl -s ifconfig.me)
VITE_WS_URL=http://$(curl -s ifconfig.me)
EOF

npm install
npm run build

# 13. Configuration Nginx
echo "🌐 Configuration Nginx..."
cat > /etc/nginx/sites-available/quizzouille <<'NGINX_EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 10M;

    # Frontend
    location / {
        root /var/quizzouille/frontend/dist;
        try_files $uri $uri/ /index.html;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }

    # Backend API
    location /api {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    # WebSocket
    location /socket.io {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_bypass $http_upgrade;
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

# 14. Démarrage backend avec PM2
echo "🚀 Démarrage du backend..."
cd /var/quizzouille/backend
pm2 delete quizzouille-backend 2>/dev/null || true
pm2 start npm --name quizzouille-backend -- start
pm2 save
pm2 startup systemd -u root --hp /root | tail -1 | bash

# 15. Créer script de mise à jour
cat > /root/deploy.sh <<'DEPLOY_EOF'
#!/bin/bash
set -e
echo "🔄 Déploiement nouvelle version..."
cd /var/quizzouille
git pull origin main
cd backend
npm install --production
npx prisma generate
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
echo "   http://$PUBLIC_IP"
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
    echo "🔒 Configuration HTTPS :"
    echo "   1. Pointer $DOMAIN vers $PUBLIC_IP"
    echo "   2. Attendre propagation DNS (5-30 min)"
    echo "   3. Exécuter : certbot --nginx -d $DOMAIN"
    echo "   4. Modifier CORS_ORIGIN dans /var/quizzouille/backend/.env"
    echo "   5. Modifier URLs dans /var/quizzouille/frontend/.env.production"
    echo "   6. Exécuter : /root/deploy.sh"
fi

echo ""
echo "🎉 Quizzouille est maintenant en ligne !"
echo "=========================================="

