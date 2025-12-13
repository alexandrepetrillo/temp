#!/bin/bash

echo "⚠️  ATTENTION : Ce script va TOUT supprimer !"
echo "   - PostgreSQL + base de données"
echo "   - Redis"
echo "   - Nginx"
echo "   - Node.js/PM2"
echo "   - L'application complète"
echo "   - Tous les backups"
echo ""
read -p "Êtes-vous sûr ? (tapez 'OUI' pour confirmer) : " CONFIRMATION

if [ "$CONFIRMATION" != "OUI" ]; then
    echo "❌ Annulation"
    exit 1
fi

echo ""
echo "🗑️  Suppression en cours..."
echo ""

# 1. Arrêter tous les services
echo "⏸️  Arrêt des services..."
pm2 delete all 2>/dev/null || true
pm2 kill 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true
pkill redis-server 2>/dev/null || true
pkill node 2>/dev/null || true

sleep 3

# 2. Supprimer PostgreSQL
echo "🗑️  Suppression PostgreSQL..."
systemctl disable postgresql 2>/dev/null || true
apt-get --purge remove -y postgresql postgresql-* postgresql-client-* postgresql-common
deluser postgres 2>/dev/null || true
delgroup postgres 2>/dev/null || true
rm -rf /var/lib/postgresql/
rm -rf /etc/postgresql/
rm -rf /var/log/postgresql/
rm -rf /usr/lib/postgresql/
rm -rf /usr/share/postgresql/

# 3. Supprimer Redis
echo "🗑️  Suppression Redis..."
systemctl disable redis-server 2>/dev/null || true
apt-get --purge remove -y redis-server redis-tools redis-*
deluser redis 2>/dev/null || true
delgroup redis 2>/dev/null || true
rm -rf /var/lib/redis/
rm -rf /etc/redis/
rm -rf /var/log/redis/
rm -rf /usr/bin/redis-*

# 4. Supprimer Nginx
echo "🗑️  Suppression Nginx..."
systemctl disable nginx 2>/dev/null || true
apt-get --purge remove -y nginx nginx-common nginx-core
rm -rf /etc/nginx/
rm -rf /var/log/nginx/
rm -rf /var/www/html/
rm -rf /usr/share/nginx/

# 5. Supprimer Node.js et PM2
echo "🗑️  Suppression Node.js et PM2..."
npm uninstall -g pm2 2>/dev/null || true
apt-get --purge remove -y nodejs npm
rm -rf /usr/local/lib/node_modules/
rm -rf /usr/local/bin/node
rm -rf /usr/local/bin/npm
rm -rf /usr/local/bin/pm2
rm -rf ~/.npm
rm -rf ~/.pm2
rm -rf /root/.pm2
rm -rf /root/.npm

# 6. Supprimer l'application complète
echo "🗑️  Suppression de l'application..."
rm -rf /var/www/quizzouille/
rm -rf /var/www/

# 7. Supprimer tous les backups
echo "🗑️  Suppression des backups..."
rm -rf /var/backups/quizzouille/
rm -rf /var/backups/postgresql/

# 8. Supprimer les scripts de déploiement
echo "🗑️  Suppression des scripts..."
#rm -f /root/deploy-hetzner.sh
#rm -f /root/deploy.sh
rm -f /root/backup-db.sh
rm -f /root/cleanup-all.sh
rm -f /root/fix-redis.sh
rm -f /root/reset-passwords.sh

# 9. Supprimer les logs système
echo "🗑️  Nettoyage des logs..."
rm -rf /var/log/pm2/
journalctl --vacuum-time=1s 2>/dev/null || true

# 10. Nettoyer les paquets orphelins
echo "🧹 Nettoyage du système..."
apt-get autoremove -y
apt-get autoclean -y
apt-get clean

# 11. Vérifier les processus restants
echo ""
echo "🔍 Vérification des processus restants..."
REMAINING_POSTGRES=$(ps aux | grep postgres | grep -v grep | wc -l)
REMAINING_REDIS=$(ps aux | grep redis | grep -v grep | wc -l)
REMAINING_NODE=$(ps aux | grep node | grep -v grep | wc -l)
REMAINING_NGINX=$(ps aux | grep nginx | grep -v grep | wc -l)

if [ $REMAINING_POSTGRES -gt 0 ] || [ $REMAINING_REDIS -gt 0 ] || [ $REMAINING_NODE -gt 0 ] || [ $REMAINING_NGINX -gt 0 ]; then
    echo "⚠️  Processus restants détectés, nettoyage forcé..."
    pkill -9 postgres 2>/dev/null || true
    pkill -9 redis 2>/dev/null || true
    pkill -9 node 2>/dev/null || true
    pkill -9 nginx 2>/dev/null || true
    sleep 2
fi

# 12. Supprimer les utilisateurs système
echo "🗑️  Suppression des utilisateurs système..."
deluser --remove-home postgres 2>/dev/null || true
deluser --remove-home redis 2>/dev/null || true
deluser --remove-home www-data 2>/dev/null || true

echo ""
echo "✅ SUPPRESSION TERMINÉE !"
echo ""
echo "📊 État final :"
echo "   PostgreSQL : $(systemctl is-active postgresql 2>/dev/null || echo 'supprimé')"
echo "   Redis      : $(systemctl is-active redis-server 2>/dev/null || echo 'supprimé')"
echo "   Nginx      : $(systemctl is-active nginx 2>/dev/null || echo 'supprimé')"
echo "   PM2        : $(pm2 list 2>/dev/null | grep -c online || echo '0 processus')"
echo ""
echo "📝 Pour réinstaller :"
echo "   1. Copiez le script deploy-hetzner.sh sur le serveur"
echo "   2. Lancez : /root/deploy-hetzner.sh"
echo ""
echo "💾 Espace disque libéré : $(df -h / | tail -1 | awk '{print $4}') disponibles"
echo ""
echo "🔄 Un redémarrage est recommandé : reboot"
