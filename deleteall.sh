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

# 1. Arrêter tous les processus
echo "⏸️  Arrêt des services..."
pm2 delete all 2>/dev/null || true
pm2 kill 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true
systemctl stop redis 2>/dev/null || true
sleep 2

# Force kill si nécessaire
pkill -9 nginx 2>/dev/null || true
pkill -9 redis-server 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true
pkill -9 node 2>/dev/null || true
sleep 2

# 2. Forcer la reconfiguration dpkg
echo "🔧 Correction dpkg..."
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null || true

# 3. Supprimer Nginx (avec gestion d'erreurs)
echo "🗑️  Suppression Nginx..."
systemctl disable nginx 2>/dev/null || true
apt-mark unhold nginx nginx-common nginx-core 2>/dev/null || true
apt-get purge -y nginx nginx-* 2>/dev/null || true
dpkg --remove --force-remove-reinstreq nginx nginx-common nginx-core 2>/dev/null || true
dpkg --purge --force-remove-reinstreq nginx nginx-common nginx-core 2>/dev/null || true
rm -rf /etc/nginx/
rm -rf /var/log/nginx/
rm -rf /var/lib/nginx/
rm -rf /usr/share/nginx/

# 4. Supprimer PostgreSQL
echo "🗑️  Suppression PostgreSQL..."
systemctl disable postgresql 2>/dev/null || true
apt-get purge -y postgresql postgresql-* 2>/dev/null || true
dpkg --remove --force-remove-reinstreq postgresql* 2>/dev/null || true
deluser postgres 2>/dev/null || true
delgroup postgres 2>/dev/null || true
rm -rf /var/lib/postgresql/
rm -rf /etc/postgresql/
rm -rf /var/log/postgresql/

# 5. Supprimer Redis
echo "🗑️  Suppression Redis..."
systemctl disable redis-server 2>/dev/null || true
systemctl disable redis 2>/dev/null || true
apt-get purge -y redis-server redis-tools redis-* 2>/dev/null || true
dpkg --remove --force-remove-reinstreq redis* 2>/dev/null || true
deluser redis 2>/dev/null || true
delgroup redis 2>/dev/null || true
rm -rf /var/lib/redis/
rm -rf /etc/redis/
rm -rf /var/log/redis/

# 6. Supprimer Node.js et PM2
echo "🗑️  Suppression Node.js..."
npm uninstall -g pm2 2>/dev/null || true
apt-get purge -y nodejs npm 2>/dev/null || true
rm -rf /usr/local/lib/node_modules/
rm -rf /usr/local/bin/node
rm -rf /usr/local/bin/npm
rm -rf /usr/local/bin/pm2
rm -rf ~/.npm
rm -rf ~/.pm2
rm -rf /root/.pm2
rm -rf /root/.npm

# 7. Supprimer l'application
echo "🗑️  Suppression application..."
rm -rf /var/quizzouille/
rm -rf /var/www/quizzouille/

# 8. Supprimer les backups
echo "🗑️  Suppression backups..."
rm -rf /root/backups/
rm -rf /var/backups/

# 9. Supprimer les scripts
echo "🗑️  Suppression scripts..."
rm -f /root/deploy*.sh
rm -f /root/backup*.sh
rm -f /root/fix*.sh
rm -f /root/cleanup*.sh
rm -f /root/reset*.sh
rm -f /root/delete*.sh

# 10. Nettoyer dpkg et APT
echo "🧹 Nettoyage dpkg..."
dpkg --configure -a
apt-get install -f -y
apt-get autoremove -y --purge
apt-get autoclean -y
apt-get clean

# Supprimer les paquets cassés
dpkg -l | grep '^rc' | awk '{print $2}' | xargs dpkg --purge 2>/dev/null || true

# Reconstruire le cache APT
rm -rf /var/lib/apt/lists/*
apt-get update

# 11. Nettoyer les journaux
echo "🗑️  Nettoyage logs..."
journalctl --vacuum-time=1s 2>/dev/null || true
rm -rf /var/log/pm2/

# 12. Vérification finale
echo ""
echo "🔍 Vérification finale..."
echo "   PostgreSQL : $(systemctl is-active postgresql 2>&1 || echo 'supprimé ✓')"
echo "   Redis      : $(systemctl is-active redis-server 2>&1 || echo 'supprimé ✓')"
echo "   Nginx      : $(systemctl is-active nginx 2>&1 || echo 'supprimé ✓')"
echo "   PM2        : $(pm2 list 2>&1 | grep -c 'online' || echo '0 processus ✓')"
echo ""

# Vérifier les processus restants
REMAINING=$(ps aux | grep -E 'postgres|redis|nginx|node' | grep -v grep | wc -l)
if [ $REMAINING -gt 0 ]; then
    echo "⚠️  Processus restants détectés :"
    ps aux | grep -E 'postgres|redis|nginx|node' | grep -v grep
    echo ""
    echo "Voulez-vous les forcer à s'arrêter ? (O/n)"
    read -r FORCE_KILL
    if [ "$FORCE_KILL" != "n" ]; then
        pkill -9 postgres 2>/dev/null || true
        pkill -9 redis 2>/dev/null || true
        pkill -9 nginx 2>/dev/null || true
        pkill -9 node 2>/dev/null || true
        echo "✅ Processus tués"
    fi
fi

echo ""
echo "✅ SUPPRESSION TERMINÉE !"
echo ""
echo "💾 Espace disque libéré : $(df -h / | tail -1 | awk '{print $4}') disponibles"
echo ""
echo "📝 Prochaines étapes :"
echo "   1. Redémarrez la VM : reboot"
echo "   2. Après redémarrage, lancez : /root/deploy-hetzner.sh"
echo ""
echo "🔄 Redémarrer maintenant ? (O/n)"
read -r REBOOT_NOW
if [ "$REBOOT_NOW" != "n" ]; then
    echo "🔄 Redémarrage dans 5 secondes..."
    sleep 5
    reboot
fi
