#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   CORRECTION UFW - Autoriser install-01 partout                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

INSTALL_IP="10.0.0.250"

echo ""
echo "Ce script autorise l'IP d'install-01 ($INSTALL_IP) sur TOUS les serveurs"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CORRECTION UFW - Serveurs HAProxy ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for HAPROXY in 10.0.0.11 10.0.0.12; do
    echo "→ HAProxy $HAPROXY..."
    ssh -o StrictHostKeyChecking=no root@$HAPROXY "
        # Autoriser install-01
        ufw allow from $INSTALL_IP comment 'Install server'
        
        # Autoriser réseau privé complet
        ufw allow from 10.0.0.0/16 comment 'Private network'
        
        # Autoriser les réseaux K3s
        ufw allow from 10.42.0.0/16 comment 'K3s pods'
        ufw allow from 10.43.0.0/16 comment 'K3s services'
        
        # Ports HAProxy
        ufw allow 5432/tcp comment 'PostgreSQL'
        ufw allow 5433/tcp comment 'PostgreSQL read'
        ufw allow 4632/tcp comment 'PgBouncer'
        ufw allow 8404/tcp comment 'HAProxy stats'
        ufw allow 8405/tcp comment 'HAProxy stats secondary'
        
        ufw reload
    " >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK HAProxy $HAPROXY configuré"
    else
        echo -e "  $KO HAProxy $HAPROXY erreur"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CORRECTION UFW - Serveurs PostgreSQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for PG in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo "→ PostgreSQL $PG..."
    ssh -o StrictHostKeyChecking=no root@$PG "
        ufw allow from $INSTALL_IP comment 'Install server'
        ufw allow from 10.0.0.0/16 comment 'Private network'
        ufw allow from 10.42.0.0/16 comment 'K3s pods'
        ufw allow from 10.43.0.0/16 comment 'K3s services'
        ufw allow 5432/tcp comment 'PostgreSQL'
        ufw allow 8008/tcp comment 'Patroni API'
        ufw reload
    " >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK PostgreSQL $PG configuré"
    else
        echo -e "  $KO PostgreSQL $PG erreur"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CORRECTION UFW - Serveurs Redis ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for REDIS in 10.0.0.123 10.0.0.124 10.0.0.125; do
    echo "→ Redis $REDIS..."
    ssh -o StrictHostKeyChecking=no root@$REDIS "
        ufw allow from $INSTALL_IP comment 'Install server'
        ufw allow from 10.0.0.0/16 comment 'Private network'
        ufw allow from 10.42.0.0/16 comment 'K3s pods'
        ufw allow from 10.43.0.0/16 comment 'K3s services'
        ufw allow 6379/tcp comment 'Redis'
        ufw allow 26379/tcp comment 'Redis Sentinel'
        ufw reload
    " >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Redis $REDIS configuré"
    else
        echo -e "  $KO Redis $REDIS erreur"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CORRECTION UFW - Serveurs RabbitMQ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for RABBITMQ in 10.0.0.126 10.0.0.127 10.0.0.128; do
    echo "→ RabbitMQ $RABBITMQ..."
    ssh -o StrictHostKeyChecking=no root@$RABBITMQ "
        ufw allow from $INSTALL_IP comment 'Install server'
        ufw allow from 10.0.0.0/16 comment 'Private network'
        ufw allow from 10.42.0.0/16 comment 'K3s pods'
        ufw allow from 10.43.0.0/16 comment 'K3s services'
        ufw allow 5672/tcp comment 'AMQP'
        ufw allow 15672/tcp comment 'Management'
        ufw allow 4369/tcp comment 'Erlang Port Mapper'
        ufw allow 25672/tcp comment 'Clustering'
        ufw reload
    " >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK RabbitMQ $RABBITMQ configuré"
    else
        echo -e "  $KO RabbitMQ $RABBITMQ erreur"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CORRECTION UFW - Workers K3s (NodePorts) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for WORKER in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo "→ Worker $WORKER..."
    ssh -o StrictHostKeyChecking=no root@$WORKER "
        ufw allow from $INSTALL_IP comment 'Install server'
        ufw allow from 10.0.0.0/16 comment 'Private network'
        ufw allow from 10.42.0.0/16 comment 'K3s pods'
        ufw allow from 10.43.0.0/16 comment 'K3s services'
        
        # NodePorts Ingress
        ufw allow 31695/tcp comment 'Ingress HTTP'
        ufw allow 32720/tcp comment 'Ingress HTTPS'
        
        # NodePorts apps
        ufw allow 30678/tcp comment 'n8n'
        ufw allow 30400/tcp comment 'litellm'
        ufw allow 30300/tcp comment 'chatwoot'
        ufw allow 30633/tcp comment 'qdrant'
        
        ufw reload
    " >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Worker $WORKER configuré"
    else
        echo -e "  $KO Worker $WORKER erreur"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ VÉRIFICATION POST-CORRECTION ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Test PostgreSQL 5432..."
if timeout 3 bash -c "nc -zv 10.0.0.10 5432" 2>&1 | grep -q succeeded; then
    echo -e "  $OK Port 5432 accessible"
else
    echo -e "  $KO Port 5432 inaccessible"
fi

echo "→ Test PgBouncer 4632..."
if timeout 3 bash -c "nc -zv 10.0.0.10 4632" 2>&1 | grep -q succeeded; then
    echo -e "  $OK Port 4632 accessible"
else
    echo -e "  $KO Port 4632 inaccessible"
fi

echo "→ Test Redis 6379..."
if timeout 3 bash -c "echo PING | nc 10.0.0.10 6379" 2>&1 | grep -q PONG; then
    echo -e "  $OK Redis accessible"
else
    echo -e "  $KO Redis inaccessible"
fi

echo "→ Test RabbitMQ 5672..."
if timeout 3 bash -c "nc -zv 10.0.0.10 5672" 2>&1 | grep -q succeeded; then
    echo -e "  $OK Port 5672 accessible"
else
    echo -e "  $KO Port 5672 inaccessible"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CORRECTION UFW TERMINÉE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Prochaine étape :"
echo "  ./01_verify_prerequisites.sh  (devrait être tout vert)"
echo ""
