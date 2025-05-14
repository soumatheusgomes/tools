# Zapbox Production Stack

> **Redis 7.2**, **RabbitMQ 3-management**, **PostgreSQL 16**, protegidos por **Traefik 3** com SSL automático (Let's Encrypt – DNS-01 via Cloudflare).

---

## 1. Pré-requisitos

| Item | Versão mínima |
|------|---------------|
| Docker | 24.0 |
| Docker Compose | v2.27 |
| Domínios A/AAAA | `redis.zapbox.me`, `rabbitmq.zapbox.me`, `postgres.zapbox.me` apontando para o host |
| API Token Cloudflare | “Zone → DNS Edit” |

---

## 2. Estrutura

```
.
├── docker-compose.yml      # stack principal
├── .env                    # variáveis sensíveis
└── README.md               # este guia
```

- **Traefik** termina TLS (443) e faz proxy TCP para Redis/PG/RabbitMQ ou HTTP para RabbitMQ UI.  
- Dados persistem em volumes dedicados.  
- Healthchecks ativam políticas de reinício “unless-stopped”, garantindo auto-heal.

---

## 3. Primeiros Passos

```bash
# 1. Copie e edite variáveis
cp .env.example .env
vim .env                    # ajuste senhas/versões

# 2. Suba a stack
docker compose up -d

# 3. Logs agregados
docker compose logs -f
```

Traefik emite/renova certificados automaticamente (cron interno ACME a cada 12 h).  
Valide em `https://traefik.zapbox.me` (caso habilite o dashboard).

---

## 4. Operações Comuns

| Ação | Comando |
|------|---------|
| **Start** | `docker compose up -d` |
| **Stop** | `docker compose down` |
| **Upgrade images** | `docker compose pull && docker compose up -d` |
| **Backup Postgres** | `docker exec -ti postgres pg_dump -U $POSTGRES_USER $POSTGRES_DB > backup.sql` |
| **Reset senha Redis** | Edite `.env`, `docker compose up -d redis` |

---

## 5. Troubleshooting

| Sintoma | Passos de diagnóstico |
|---------|----------------------|
| ❌ Certificado inválido | `docker logs traefik | grep acme` – verifique token CF |
| ❌ Redis “DENIED” | Confirme `REDIS_PASSWORD`, teste `redis-cli -a $REDIS_PASSWORD -h redis.zapbox.me` |
| ⏳ RabbitMQ 504 | Verifique healthcheck `docker inspect rabbitmq` → `Health.Status` |
| 🔒 Conexão Postgres falha | `psql "sslmode=require host=postgres.zapbox.me user=$POSTGRES_USER"` |

---

## 6. Boas Práticas e Hardening

1. **Firewall externo** – abra apenas 80/443/6379/5432/5672 (ou whiteliste IPs dos clientes).  
2. **NetworkPolicy interna** – mantenha serviços críticos só na rede `backend`.  
3. **TLS interno (avançado)** – habilite stunnel ou configurações nativas para criptografia end-to-end.  
4. **Backups automáticos** – cron `pg_dump` + sync S3 / R2.  
5. **Monitoramento** – Prometheus + Grafana via exporters (`redis_exporter`, `postgres_exporter`, `rabbitmq_exporter`).  
6. **Resource limits** – adicione `mem_limit`, `cpus`, `ulimits` conforme carga prevista.  
7. **Multi-AZ** – use Docker Swarm/Kubernetes + volumes replicados (e.g. Longhorn) para alta disponibilidade.  
8. **Secrets Engine** – migre senhas para Docker Secrets ou HashiCorp Vault em ambientes críticos.

---

## 7. Atualizando Versões

- **Redis 8** e **PostgreSQL 17** ainda não possuem imagens estáveis no Docker Hub; quando forem lançadas, basta alterar `*_VERSION` no `.env`, executar **pull** e **up**.  
- Mantenha Traefik sempre na `minor` mais recente para receber patches ACME.

---

## 8. Desligamento Seguro

```bash
docker compose down --timeout 30   && docker volume prune -f          # mantenha só se tiver backup!
```

---

### Fim 😊
