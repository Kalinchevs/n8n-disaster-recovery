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
6. Восстанавливает Selfhost AI и до создания контейнеров предлагает сохранить прежний либо выбрать новый базовый домен.
7. Для нового домена показывает рассчитанную замену заполненных `*_HOSTNAME`, изменяет только их и проверяет итоговый `WEBHOOK_URL`.
8. Восстанавливает PostgreSQL и при остановленном n8n устанавливает `active=false` всем первоначально опубликованным workflow, удаляет их восстановленные маршруты из `webhook_entity` и сохраняет ID, названия и наличие `Telegram Trigger` в recovery workspace.
9. Восстанавливает volumes, Playwright и backup automation.
10. Не запускает production n8n без точного подтверждения `ACTIVATE`; после запуска все восстановленные workflow остаются `Unpublished`.
11. Только после точного `WORKFLOWS` возвращает `active=true` первоначально опубликованным workflow без Telegram Trigger и перезапускает основной n8n.
12. Только после проверки DNS/HTTPS и точного `TELEGRAM` возвращает `active=true` Telegram-workflow, перезапускает основной n8n и переносит webhook на выбранный hostname и публичный IPv4 нового VPS.
13. Включает backup timer только после успешной проверки `sftp homenas-backup`.

Импорт PostgreSQL выполняется с компактной строкой прогресса и прошедшим временем. Подробный вывод `psql` сохраняется отдельно в `${RECOVERY_RUN}/postgres-restore.log`; при ошибке скрипт останавливается и сообщает путь к нему.

Каждая интерактивная попытка авторизации Tailscale ограничена пятью минутами. Если VPS не получил Tailscale IPv4, мастер предлагает повтор и запускает следующую попытку с `--force-reauth`, чтобы не переиспользовать устаревшую ссылку.

Основной и Playwright Compose запускаются с `--progress quiet`: прогресс отдельных Docker-слоёв скрыт, а этапы recovery, предупреждения и ошибки сохраняются.

После восстановления требуется отключить Tailscale key expiry для нового VPS и выполнить пробный Restic backup.

## Поддержка произвольного публичного домена

После извлечения snapshot скрипт читает прежний базовый домен из `N8N_HOSTNAME` и предлагает новый. Нажатие Enter сохраняет восстановленные hostname без изменений.

При вводе нового базового домена скрипт:

1. Валидирует его как публичный DNS hostname без схемы, пути и порта.
2. Находит заполненные переменные `*_HOSTNAME`, использующие прежний доменный суффикс.
3. Сохраняет префиксы сервисов и показывает полную рассчитанную замену.
4. Требует точного подтверждения `DOMAIN`.
5. Перезаписывает только выбранные строки `*_HOSTNAME`, не выполняя глобальную замену по `.env`.
6. Проверяет Docker Compose и соответствие итогового `WEBHOOK_URL` значению `https://<N8N_HOSTNAME>`.

Caddy сможет получить сертификат нового публичного домена при корректных A/AAAA, доступных портах 80/443 и отсутствии несовместимого custom TLS certificate.

## Telegram при смене домена

Изоляция выполняется до первого запуска n8n прямым изменением `workflow_entity.active` для всех опубликованных workflow в уже восстановленной PostgreSQL. Поскольку n8n в этот момент остановлен, операция не вызывает lifecycle триггеров. Обычные workflow и Telegram-workflow сохраняются в разных логических группах: первые можно вернуть в исходное состояние подтверждением `WORKFLOWS`, вторые — только отдельным `TELEGRAM`.

Это позволяет запустить восстановленную систему с полностью `Unpublished` workflow для безопасной проверки и устраняет сценарий, при котором одно подтверждение `ACTIVATE` на тестовой машине заменяло production-webhook ещё до запроса `TELEGRAM`, а последующая остановка тестовой машины могла удалить webhook полностью.

Если `TELEGRAM` не подтверждён либо DNS/HTTPS не готовы, изолированные workflow остаются неактивными и старый webhook не меняется. После подтверждения код возвращает только сохранённым workflow состояние `active=true`, перезапускает основной n8n, получает текущий URL через Telegram `getWebhookInfo` и передаёт URL в `setWebhook` вместе с `ip_address`, `secret_token` и `allowed_updates`. После операции проверяются одновременно URL и IP.

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
