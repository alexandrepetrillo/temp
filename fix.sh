#!/bin/bash

echo "🔧 Fix Redis..."

# Arrêter tous les processus Redis
sudo pkill redis-server 2>/dev/null || true
sleep 2

# Nettoyer
sudo apt-get purge -y redis-server redis-tools
sudo rm -rf /var/lib/redis/*
sudo rm -rf /var/log/redis/*

# Réinstaller
sudo apt-get update
sudo apt-get install -y redis-server

# Corriger les permissions
sudo chown -R redis:redis /var/lib/redis
sudo chown -R redis:redis /var/log/redis
sudo chmod 750 /var/lib/redis
sudo chmod 750 /var/log/redis

# Configurer pour démarrer automatiquement
sudo systemctl enable redis-server
sudo systemctl start redis-server

# Vérifier
sudo systemctl status redis-server

echo ""
echo "✅ Redis devrait être opérationnel !"
