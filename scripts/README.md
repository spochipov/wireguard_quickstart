# Scripts — описание вспомогательных утилитов

Этот файл описывает скрипты, находящиеся в каталоге `scripts/`. Скрипты предназначены для администрирования WireGuard-сервера и упрощают следующие задачи: настройка фаервола, смена порта, диагностика, сбор логов и сохранение правил.

Список скриптов и назначение
- change-wg-port.sh
  - Назначение: безопасно изменить ListenPort в `/etc/wireguard/wg0.conf`, обновить правила firewall (iptables/ip6tables), попытаться обновить UFW/Firewalld и сохранить правила через netfilter-persistent.
  - Использование: `sudo change-wg-port <new_port>` (после установки скрипт копируется в `/usr/local/bin/change-wg-port`).
  - Примечание: делает резервную копию `wg0.conf` перед изменением.

- wg-firewall-recommendations.sh
  - Назначение: рекомендации и опциональное применение базовых правил firewall для WireGuard (dry-run по умолчанию).
  - Использование: `./wg-firewall-recommendations.sh` (dry-run), `./wg-firewall-recommendations.sh apply` (применить).

- add-wg-input-rule.sh
  - Назначение: добавить правило INPUT для UDP 51820 (WireGuard) в iptables/ip6tables/nft при необходимости.
  - Использование: `./add-wg-input-rule.sh` (dry-run), `./add-wg-input-rule.sh apply` (применить).

- clean-duplicates-and-save.sh
  - Назначение: удалить дублирующиеся правила INPUT для порта WireGuard и сохранить итоговые правила в `/etc/iptables/rules.v4` и `/etc/iptables/rules.v6`.
  - Использование: `sudo ./clean-duplicates-and-save.sh`

- run-wg-diagnostics-and-collect.sh
  - Назначение: запустить `wg-debug-internet.sh`, снять снимки iptables/ip6tables/nft, маршруты и попытаться выполнить curl через интерфейс wg0; сохранить выводы в `/tmp/wg-diagnostics-<timestamp>`.
  - Использование: `sudo ./run-wg-diagnostics-and-collect.sh`

- WG_apply_commands.txt
  - Назначение: набор рекомендуемых команд для ручного применения (добавление правил, NAT, проверка ip_forward и т.д.)

Рекомендации по использованию
- Запускайте скрипты от root.
- Перед применением любых изменений делайте резервную копию конфигурации `/etc/wireguard/wg0.conf`.
- Если вы используете nftables напрямую (не через iptables-nft), проверяйте совместимость изменений и вносите правки в nft, а не в iptables.
- Для автоматического восстановления правил после перезагрузки установите `iptables-persistent` / `netfilter-persistent`.

Файлы конфигурации (результат работы скриптов)
- `/etc/iptables/rules.v4` — сохранённые IPv4 правила
- `/etc/iptables/rules.v6` — сохранённые IPv6 правила (если ip6tables-save доступен)
- `/etc/wireguard/wg0.conf.bak.*` — резервные копии конфигурации, создаваемые скриптами

Контакт/поддержка
- Issues: https://github.com/spochipov/wireguard_quickstart/issues
