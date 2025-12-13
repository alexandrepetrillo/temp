#!/bin/bash

echo "🔧 Fix de l'installation Nginx..."

# 1. Arrêter Nginx si en cours
systemctl stop nginx 2>/dev/null || true
pkill nginx 2>/dev/null || true

# 2. Reconfigurer dpkg
echo "📦 Nettoyage dpkg..."
dpkg --configure -a
apt-get install -f -y

# 3. Supprimer les paquets Nginx problématiques
echo "🗑️ Suppression Nginx..."
apt-get purge -y nginx nginx-common nginx-core 2>/dev/null || true
apt-get autoremove -y
apt-get autoclean -y

# 4. Nettoyer les fichiers de configuration résiduels
rm -rf /etc/nginx/
rm -rf /var/log/nginx/
rm -rf /usr/share/nginx/
rm -rf /var/lib/nginx/

# 5. Corriger les dépendances cassées
apt-get update
apt-get install -f -y

# 6. Réinstaller Nginx proprement
echo "📦 Réinstallation Nginx..."
apt-get install -y nginx

# 7. Vérifier l'installation
if systemctl is-active --quiet nginx; then
    echo "✅ Nginx fonctionne !"
else
    echo "🚀 Démarrage Nginx..."
    systemctl start nginx
    systemctl enable nginx
fi

# 8. Afficher le statut
systemctl status nginx --no-pager

echo ""
echo "✅ Fix Nginx terminé !"
