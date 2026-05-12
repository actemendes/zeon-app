# Мобильный payment flow (архитектура payment-session)

Приложение: `com.zeon.hiddify`.

Документ фиксирует текущее поведение оплаты в приложении: единый `user_id`, создание `payment_session_id`, возврат через deep link, проверку статуса, фоновое восстановление без deep link и обновление managed-профиля.

## 1. Единый канонический user_id

### Канонический ключ
- Ключ в `SharedPreferences`: `mobile_auto_import_user_id`.
- Владельцы этого `user_id`: bind/import/bootstrap цепочка (`MobileConnLinkImportService`, `MobileBindService`, `MobileBootstrapImportService`).
- Payment flow обязан использовать только этот канонический `user_id`.

### Legacy-ключ
- Legacy-ключ: `mobile_payment_user_id`.
- Он используется только как миграционный fallback:
1. Сначала читается `mobile_auto_import_user_id`.
2. Если канонический найден: используется он, legacy-ключ удаляется.
3. Если канонический пуст, а legacy найден: legacy переносится в канонический и удаляется.
4. Для старых cold-start кейсов допускается создание/поиск пользователя через `POST /api/mobile/users/create` с последующим сохранением канонического ключа.

## 2. Создание платежа (новый backend-контракт)

`MobilePaymentService.createPayment(plan)` отправляет:
- `POST /api/mobile/payments/create`
- payload:
1. `user_id` (канонический)
2. `device_id`
3. `plan`
4. `source = "app"`

Обработка ответа:
- берется `confirmation_url`;
- извлекается `payment_session_id` (`payment_session_id` / `paymentSessionId` / `sid`);
- `sid` сохраняется в `mobile_payment_session_id`;
- дополнительно сохраняется время создания `mobile_payment_session_created_at_ms`;
- открывается checkout URL.

## 3. Возврат в приложение через deep link

Ожидаемый формат:
- `zeon://payment-result?sid=<payment_session_id>`

Парсинг и роутинг:
- deep link распознается через `extractPaymentSessionIdFromDeepLink(...)`;
- при наличии `sid` router редиректит в `/profile-payment?sid=<sid>`;
- параллельно глобальный слушатель app-links (`RefreshListenable`) запускает обработку `sid` напрямую, чтобы post-payment логика не зависела от того, открыт ли экран оплаты.

## 4. Проверка статуса платежа и polling

После получения `sid` вызывается `MobilePaymentService.processPaymentSessionReturn(...)`:
1. `GET /api/mobile/payments/status?sid=<sid>`
2. При `status=pending` выполняется polling с backoff.
3. Если `status=succeeded`:
- проверяется соответствие `status.user_id` каноническому `mobile_auto_import_user_id`;
- при mismatch завершается ошибкой `user_id_mismatch`.
 - из status payload дополнительно извлекаются данные для обновления профиля:
1. `subscription.status` / `subscription_status`
2. `subscription.expires_at` / `expires_at`
3. `user.login` / `login`
4. Если `status=canceled` или `status=failed`:
- polling останавливается, сессия считается терминальной.
5. Если backend вернул `404` по `sid`:
- состояние трактуется как `failed` с причиной `payment_session_not_found`.

## 5. Поведение при success: как обновляется профиль

Текущая реализация после `status=succeeded`:
1. Сначала выполняется `refreshActiveProfileMetadata(...)` для сохраненного managed `conn_link`.
2. В `refreshActiveProfileMetadata(...)` передаются API-данные из `payments/status` (`apiStatus`, `apiExpiresAt`, `apiLogin`), чтобы срок/статус профиля могли обновиться даже когда по самой ссылке мало метаданных.
3. Если это не сработало или сохраненный `conn_link` отсутствует, выполняется fallback: `importConnectionLink(...)` по `conn_link` из status payload (также с передачей API-данных).
4. После успешной обработки payment session дополнительно запускается тот же механизм ручного обновления remote-подписки, что используется в UI-кнопке «Обновить подписку»:
   - `updateProfileNotifierProvider(active.id).notifier.updateProfile(activeRemoteProfile)`;
   - это выполняет `upsertRemote`, при необходимости reconnect, и принудительно обновляет данные профиля в интерфейсе.

Важно:
- шаг с `importConnectionLink(...)` — это фактически ре-импорт/upsert managed-профиля;
- это не жесткое требование backend `payments/status`, а текущая реализация app-side post-payment refresh;
- `MobileConnLinkImportService` является существующим базовым механизмом проекта (используется также в bind/bootstrap), а не отдельной временной логикой только для платежа.

## 6. Возврат без deep link (пользователь просто вернулся в приложение)

Реализовано фоновое восстановление платежа в окне жизни checkout-ссылки:
1. Сохраняется последний `sid` + время создания.
2. Recovery window: до 15 минут.
3. При `AppLifecycleState.resumed` выполняется немедленная попытка проверки статуса.
4. Дополнительно работает таймер каждые 45 секунд.
5. Лимит фоновых попыток: 20.
6. У фонового тика короткий бюджет запросов статуса, у resume/deeplink — полный.
7. На терминальных состояниях (`succeeded` / `canceled` / `failed`) сохраненный `sid` очищается и recovery останавливается.

## 7. UI/UX статусы платежа

На экране оплаты показан минимальный overlay-статус:
1. Ожидание подтверждения (`waiting`)
2. Успешно (`succeeded`)
3. Отменено (`canceled`)
4. Ошибка (`failed`)

## 8. Наблюдаемость (диагностические логи)

Логируются:
- источник и значение канонического `user_id`;
- `user_id` в create-payment payload;
- созданный/обрабатываемый `sid`;
- результат `payments/status` (статус, `status_user_id`, номер попытки);
- факт старта/успеха/ошибки refresh цепочки.

Секреты (`api key`, токены) в логи не выводятся.

## 9. Текущее ограничение и продуктовый нюанс

Если продуктово требуется строго "оставлять ту же ссылку и не делать ре-импорт после оплаты", то текущая success-ветка может требовать дополнительной корректировки:
- сейчас основной путь — `refreshActiveProfileMetadata(...)` для сохраненного managed `conn_link`;
- fallback на `importConnectionLink(...)` по `status.conn_link` все еще выполняется при неуспехе refresh;
- для политики "без ре-импорта" нужно убрать или ужесточить условие вызова import (например, только при отсутствии профиля).

## 10. Уведомление об успешной оплате

В payment-цепочке добавлен пользовательский toast через `inAppNotificationController`:
- уведомление показывается при успешной обработке `sid` и обновлении managed-профиля (`refreshTriggered=true`);
- уведомление срабатывает и для `deep link`-возврата, и для `resume`/фонового recovery (с защитой от дублей по `sid`);
- текст: `Оплата прошла успешно, профиль обновлен` (или локализованный суффикс обновления профиля при наличии перевода).
- дополнительно при вызове `updateProfileNotifier` может показываться стандартное уведомление успешного обновления подписки (`profiles.msg.update.success`), т.к. используется штатный UI-механизм обновления.

## 11. Ключевые файлы реализации

- `lib/features/mobile/data/mobile_payment_service.dart`
- `lib/features/mobile/data/mobile_payment_deep_link.dart`
- `lib/core/router/go_router/routing_config_notifier.dart`
- `lib/core/router/go_router/refresh_listenable.dart`
- `lib/features/profile/overview/profile_payment_page.dart`
- `lib/features/mobile/data/mobile_conn_link_import_service.dart`

## 12. Отображение ссылок для пользователя

- Внутри приложения для обновлений/синхронизации может использоваться основной `api_link/open/$openId`.
- В user-facing UI (карточки/детали/копирование/шаринг ссылки) отображается и отдается пользователю только публичный fallback URL:
  - `https://zeon-vps.link/open/$openId`
- Это сделано для того, чтобы не раскрывать пользователю внутренний `api_link`, сохранив его для внутренней логики.
