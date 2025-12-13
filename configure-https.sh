#!/bin/bash
set -e

echo "🔒 Configuration HTTPS pour quizzouille.fun"
echo "============================================="

# ⚠️ CONFIGUREZ CES VARIABLES
DOMAIN="quizzouille.fun"
EMAIL="alexandre.petrillo@gmail.com"  # ⚠️ CHANGEZ CECI !

# 1. Vérifier que le DNS pointe bien vers ce serveur
echo "🔍 Vérification DNS..."
CURRENT_IP=$(curl -s ifconfig.me)
echo "   IP du serveur : $CURRENT_IP"

# Attendre un peu pour que dig fonctionne
sleep 2
DNS_IP=$(dig +short $DOMAIN @8.8.8.8 | head -n1)
echo "   IP DNS pour $DOMAIN : $DNS_IP"

if [ -z "$DNS_IP" ]; then
    echo "❌ ERREUR : Impossible de résoudre $DOMAIN"
    echo "   Le DNS n'est peut-être pas encore propagé"
    echo "   Attendez 5-30 minutes et réessayez"
    exit 1
fi

if [ "$CURRENT_IP" != "$DNS_IP" ]; then
    echo "⚠️  ATTENTION : Le DNS ne pointe pas encore vers ce serveur"
    echo "   IP du serveur : $CURRENT_IP"
    echo "   IP DNS : $DNS_IP"
    echo ""
    read -p "Voulez-vous continuer quand même ? (y/N) : " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation annulée. Attendez la propagation DNS et réessayez."
        exit 1
    fi
fi

echo "✅ DNS correctement configuré"

# 2. Mettre à jour Nginx avec le nom de domaine
echo "🌐 Configuration Nginx..."
cat > /etc/nginx/sites-available/quizzouille <<'NGINX_EOF'
server {
    listen 80;
    server_name quizzouille.fun www.quizzouille.fun;
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

# Tester et recharger Nginx
if nginx -t; then
    systemctl reload nginx
    echo "✅ Nginx configuré"
else
    echo "❌ Erreur dans la configuration Nginx"
    exit 1
fi

# 3. Obtenir le certificat SSL
echo "🔐 Obtention du certificat SSL avec Let's Encrypt..."
echo "   Cela peut prendre 1-2 minutes..."

if certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect; then
    echo "✅ Certificat SSL obtenu et installé"
else
    echo "❌ Erreur lors de l'obtention du certificat SSL"
    echo "   Vérifiez que :"
    echo "   - Le DNS est correctement configuré"
    echo "   - Le port 80 est ouvert"
    echo "   - Vous n'avez pas atteint la limite de Let's Encrypt"
    exit 1
fi

# 4. Mettre à jour backend .env
echo "⚙️ Mise à jour de la configuration backend..."
if [ -f /var/quizzouille/backend/.env ]; then
    # Backup de l'ancien .env
    cp /var/quizzouille/backend/.env /var/quizzouille/backend/.env.backup-$(date +%Y%m%d_%H%M%S)

    # Mettre à jour CORS_ORIGIN
    sed -i "s|CORS_ORIGIN=.*|CORS_ORIGIN=https://$DOMAIN|g" /var/quizzouille/backend/.env

    echo "✅ Backend .env mis à jour"
    echo "   CORS_ORIGIN=https://$DOMAIN"
else
    echo "⚠️  Fichier backend .env introuvable"
fi

# 5. Mettre à jour frontend .env.production
echo "🎨 Mise à jour de la configuration frontend..."
cat > /var/quizzouille/frontend/.env.production <<EOF
VITE_API_URL=https://$DOMAIN
VITE_WS_URL=https://$DOMAIN
EOF
echo "✅ Frontend .env.production mis à jour"

# 6. Rebuild frontend avec les nouvelles variables
echo "🔨 Rebuild du frontend..."
cd /var/quizzouille/frontend
if npm run build; then
    echo "✅ Frontend rebuild avec succès"
else
    echo "❌ Erreur lors du build du frontend"
    exit 1
fi

# 7. Redémarrer le backend
echo "🔄 Redémarrage du backend..."
if pm2 restart quizzouille-backend; then
    echo "✅ Backend redémarré"
else
    echo "⚠️  Erreur lors du redémarrage du backend"
fi

# 8. Recharger Nginx une dernière fois
systemctl reload nginx

# 9. Vérifier le certificat
echo ""
echo "🔍 Vérification du certificat SSL..."
certbot certificates | grep -A 10 $DOMAIN || true

echo ""
echo "✅ ✅ ✅ Configuration HTTPS terminée ! ✅ ✅ ✅"
echo "================================================"
echo ""
echo "🌐 Votre site est maintenant accessible sur :"
echo "   https://$DOMAIN"
echo "   https://www.$DOMAIN"
echo ""
echo "🔒 Certificat SSL : Installé et configuré"
echo "🔄 Renouvellement automatique : Activé (tous les 90 jours)"
echo ""
echo "📋 Tests à effectuer :"
echo "   1. Ouvrez https://$DOMAIN dans votre navigateur"
echo "   2. Vérifiez le cadenas SSL (doit être vert)"
echo "   3. Testez le login"
echo "   4. Testez de rejoindre une partie (WebSocket)"
echo ""
echo "📝 Commandes utiles :"
echo "   certbot certificates           # Voir les certificats"
echo "   certbot renew --dry-run        # Tester le renouvellement"
echo "   pm2 logs quizzouille-backend   # Voir les logs"
echo "   tail -f /var/log/nginx/error.log  # Logs Nginx"
echo ""
echo "🎉 Quizzouille est maintenant en HTTPS !"
echo "================================================"

