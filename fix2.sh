cd /var/quizzouille
git pull

# Créer la config upstream séparée
cat > /etc/nginx/conf.d/quizzouille-upstream.conf <<'EOF'
upstream quizzouille_backend {
    ip_hash;
    server 127.0.0.1:3000;
}
EOF

# Tester et recharger Nginx
nginx -t && systemctl reload nginx

# Redémarrer le backend
cd backend
npm install
npm run build
pm2 restart quizzouille-backend
