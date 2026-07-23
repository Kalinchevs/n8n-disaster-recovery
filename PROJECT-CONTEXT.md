# Контекст n8nRestore

## Назначение

Проект содержит полный контур резервного копирования и аварийного восстановления production-инсталляции Selfhost AI/n8n на новый совместимый VPS.

Основные файлы:

- `n8n-daily-backup` — ежедневная консистентная копия в Restic;
- `restore-n8n.sh` — интерактивное восстановление на свежий VPS;
- `RECOVERY-GUIDE-RU.md` — эксплуатационная инструкция;
- `docs/WINDOWS-APP-CONCEPT.md` — направление развития Windows-приложения.

## Текущая инфраструктура

| Компонент | Значение |
|---|---|
| Production n8n | `https://n8n.codecraftsergo.com/` |
| VPS для восстановления | Ubuntu 24.04 LTS amd64 |
| Selfhost AI | `/root/selfhost-ai`, проверено с версией 1.7.2 |
| PostgreSQL | 17 |
| Synology в Tailscale | `homenas` |
| SFTP-пользователь | `n8n_backup` |
| Restic path | `/n8n-backups/restic-n8n` |
| Daily backup SSH alias | `homenas-backup` |
| Restic logical host/tag | `n8n-vps` / `n8n-daily` |

Секреты в репозитории отсутствуют. Пароль Restic хранится отдельно, SFTP-пароль используется временно, а SSH-ключ backup восстанавливается из зашифрованного Restic snapshot.

## Что сохраняется

- `/root/selfhost-ai`, включая production `.env`;
- PostgreSQL databases и roles;
- n8n persistent volume и `N8N_ENCRYPTION_KEY`;
- Portainer;
- Caddy `/config` и `/data`;
- Playwright;
- Grafana, Prometheus и Databasus при включённых профилях;
- Docker registry credentials;
- backup-скрипт, systemd service/timer, Restic password file и SSH-конфигурация.

Redis и Docker-образы намеренно не копируются.

## Поведение восстановления

Скрипт:

1. Проверяет свежий VPS, Ubuntu и amd64.
2. Устанавливает Docker, Restic и Tailscale.
3. Авторизует VPS в том же tailnet и проверяет `tailscale ping` до Synology.
4. Проверяет SSH fingerprint Synology.
5. Показывает snapshots и восстанавливает выбранный.
6. Восстанавливает Selfhost AI, PostgreSQL, volumes, Playwright и backup automation.
7. Не запускает production n8n без точного подтверждения `ACTIVATE`.
8. После запуска обнаруживает активные Telegram Trigger и может закрепить их webhook за публичным IPv4 нового VPS.
9. Включает backup timer только после успешной проверки `sftp homenas-backup`.

После восстановления требуется отключить Tailscale key expiry для нового VPS и выполнить пробный Restic backup.

## Домен: текущее ограничение

Сейчас `.env` и Caddy восстанавливаются с прежними hostname. Selfhost AI использует отдельные переменные `N8N_HOSTNAME`, `WELCOME_HOSTNAME`, `PORTAINER_HOSTNAME`, `GRAFANA_HOSTNAME` и другие, а не одну общую переменную домена.

Для поддержки нового домена требуется:

1. До создания контейнеров запросить новый hostname или базовый домен.
2. Показать рассчитанную замену всех заполненных `*_HOSTNAME`.
3. Изменять только известные переменные `.env`, без глобальной замены текста.
4. Проверять результирующий `WEBHOOK_URL`, DNS и HTTPS до переноса внешних webhook.
5. Сохранять старое значение при нажатии Enter.

Caddy сможет получить сертификат нового публичного домена при корректных A/AAAA, доступных портах 80/443 и отсутствии несовместимого custom TLS certificate.

## Telegram: текущее ограничение

Текущий recovery-код получает `current.url` через Telegram `getWebhookInfo`, затем повторно передаёт тот же URL в `setWebhook` вместе с новым `ip_address`.

Это полностью корректно при смене VPS с сохранением домена. При смене домена скрипт обновит IP, но оставит старый hostname в webhook URL.

Необходимая доработка: заменить только origin URL на `https://<новый N8N_HOSTNAME>`, сохранив webhook path, `secret_token` и `allowed_updates`.

## Аудит текущих workflow

Read-only аудит production n8n через REST API от 23 июля 2026 года показал:

- один `n8n-nodes-base.telegramTrigger`;
- один `n8n-nodes-base.scheduleTrigger`;
- три `n8n-nodes-base.executeWorkflowTrigger`;
- Webhook, Form Trigger и Chat Trigger отсутствуют;
- жёстких ссылок на `codecraftsergo.com` в workflow не найдено;
- используются credential references: Telegram API, Dropbox OAuth2, IMAP, PDFBolt API и website login.

При смене домена существующий Dropbox refresh token должен продолжить работу, но для повторной OAuth-авторизации потребуется зарегистрировать callback нового домена у провайдера.

## Tailscale и backup не зависят от публичного домена

Публичный hostname n8n не участвует в маршруте backup. Новый VPS подключается к тому же tailnet, а Synology доступна по `homenas`.

Риски:

- не отключённый Tailscale key expiry;
- ACL/device approval/tags, если они отдельно включены в tailnet;
- одновременно работающие backup timers на старом и новом VPS;
- выбор в recovery-мастере нестандартного NAS/SFTP/path не меняет автоматически жёсткий `REPOSITORY` восстановленного `n8n-daily-backup`.

Последний пункт следует исправить при параметризации recovery.

## Граница понятия «произвольный VPS»

Поддерживается новый совместимый VPS, а не любая система:

- свежая Ubuntu 24.04 LTS;
- amd64;
- root-доступ;
- доступ в интернет;
- доступ к тому же Tailscale tailnet и Restic repository;
- отсутствие конфликтующих существующих контейнеров и `/root/selfhost-ai`.
