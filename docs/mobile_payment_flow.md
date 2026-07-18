# Внешняя оплата и обновление мобильной подписки

Оплата не создаётся, не показывается и не подтверждается внутри приложения.
Клиент не вызывает mobile payment API и не проверяет статус платёжной сессии.

## Пользовательский сценарий

1. Кнопки special servers и CTA строят публичную ссылку из активного remote-профиля:
   `https://zeon-vps.link/open/<user_id>#profile`.
2. Ссылка открывается во внешнем браузере.
3. Тарифы и оплата полностью обслуживаются `z-net-server`.
4. Webhook/finalize на серверной стороне обновляет статус и `expires_at` подписки в `zeon-server`.
5. При возврате в приложение клиент перечитывает обычную `/open/<user_id>` subscription-ссылку.

`user_id` не зашит в приложение: он извлекается из URL активного профиля. Ссылка
`/open/649669380#profile` является только примером конкретного аккаунта.

## Пассивная синхронизация

После успешного открытия страницы аккаунта приложение сохраняет локальный маркер.
При `AppLifecycleState.resumed` выполняются тихие попытки обновления remote-профиля
через 1, 15, 45 и 90 секунд. Это запросы самой подписки, а не статуса платежа.

После каждого успешного чтения сравнивается `SubscriptionInfo.expire` до и после
обновления. Если срок изменился:

- новый профиль уже сохранён в локальной БД;
- UI автоматически показывает новый срок;
- активное VPN-подключение переподключается, только если оно было подключено;
- пользователь получает стандартное уведомление об обновлении подписки;
- дополнительные попытки прекращаются.

Если изменение не появилось за окно быстрых попыток, специальная проверка
завершается. Обычный `ForegroundProfilesUpdateNotifier` продолжает плановое
автообновление remote-профилей раз в 15 минут с учётом их update interval.

## Серверная ответственность

- `z-net-server`: веб-кабинет, цены, создание checkout и приём YooKassa webhook.
- `zeon-server`: атомарный finalize payment quote, обновление `subscriptions.status`
  и `subscriptions.expires_at`, выдача актуального subscription profile.
- `zeon-app`: только внешний переход и чтение уже обновлённой подписки.

## Ключевые файлы

- `lib/features/mobile/data/external_subscription_sync_service.dart`
- `lib/features/profile/overview/external_subscription_account.dart`
- `lib/core/router/go_router/refresh_listenable.dart`
- `lib/features/home/widget/home_premium_access_button.dart`
- `lib/features/profile/overview/profile_menu_page.dart`
