# ZEON Stage 2.9 — Global data-plane recovery

Дата физической проверки: 2026-07-31  
Устройство: OnePlus GM1901, Android 16 / API 36  
ADB serial: `18bfc103`  
Production package: `com.zeon.hiddify`

## Итог

```text
Global data plane: FAIL
Root cause: PARTIALLY PROVEN
Russia regression: FAIL
Lifecycle: PASS
Overall: FAIL
```

PASS не выдан. Exact production candidate открыл YouTube 5/5 и Telegram
5/5, подтвердил HTTP/3 и обычные последовательные transfers, но не завершил
ни один из трёх засчитанных Cloudflare browser Speedtest, а parallel upload
дал только 17/20. Exact-production Russia browser sweep после screen-off не
был выполнен: телефон вернулся на PIN keyguard, который не обходился.

## 1. Exact reproduction

Исходная проблема повторена на exact Stage 2.8 production APK ревизии
`07158f91` и SHA-256
`adbb338b3312dc39353de7f43bc6c17866263d4fdc0e358872f82e51f64c80d9`.

- Global был выбран до подключения;
- старый VPN полностью остановлен;
- создана новая generation;
- Android VPN имел `IS_VALIDATED`;
- TUN и core были запущены;
- `route.final = select`;
- Global DNS завершался на `dns-remote`;
- Global config не содержал RU DIRECT rule sets.

Browser result:

| Проверка | Результат |
|---|---|
| example.com | `ERR_CONNECTION_CLOSED` |
| YouTube | `ERR_CONNECTION_CLOSED` |
| Telegram public | `ERR_CONNECTION_CLOSED` |
| Cloudflare Speedtest | `ERR_FAILED` |
| Cloudflare QUIC endpoint | HTTP 200, h3 |

Это подтверждает частичный, преимущественно TCP/service-dependent failure,
а не полный отказ Android VPN, TUN, DNS или UDP/443.

## 2. Effective config Stage 2.7 / Stage 2.8

Сравнивались redacted **effective configs после всех Dart/Go
transformations**, а не исходный profile JSON:

```text
Stage 2.7 SHA-256: 0424e50b3764c372b5048635119d33c20ace6f7ffe5a5fce901fbce596930db4
Stage 2.8 SHA-256: 0424e50b3764c372b5048635119d33c20ace6f7ffe5a5fce901fbce596930db4
changed lines: 0
```

В обоих configs:

- `route.final = select`;
- `dns.final = dns-remote`;
- `independent_cache = true`;
- TUN MTU = 1500;
- FakeIP/FakeDNS declaration отсутствует;
- `zapret-ru-domains`, `zapret-ru-ip`, `zeon-ru-yandex` и
  `zeon-ru-wildberries` в Global отсутствуют.

Следовательно, Stage 2.8 Russia transformation не проникла в effective
Global config. Полный текст сравнения находится в
`out/stage2-9/global-config-diff.txt`.

## 3. Core AAR diff

Исходные AAR:

```text
Stage 2.7: 4fea6918da38b746c89cb98a904fdc0fa83b8f77ab2b22352c8d6064e29c6f43
Stage 2.8: 6190b8a5396a105f4f3b9c966dfb340bc8f00045bc49975c9a149d57798eac96
```

Root tree diff `2581859a..07158f91` затронул 37 core files: 3084 additions,
179 deletions. Изменения классифицированы как:

- Russia routing/rule-set installation: builder, bundled SRS, Yandex,
  Wildberries, RU DNS policy;
- DNS reverse mapping/CNAME correlation: DNS router;
- telemetry-only: `common/zeonvalidation`, tagged DNS/route hooks;
- generation ABI: `Mobile.setSessionGeneration`;
- route correlation: dialer/route hooks;
- unrelated Global data-plane change: не найдено.

Java API отличался только `Mobile.setSessionGeneration(long)`. Для A/B был
собран Stage 2.7 compatibility core с backport только этого ABI метода
(`fca593109605642a1e159953cce7a30cba3193ee`). Его browser failures были теми
же, что у Stage 2.8. Полный exact Stage 2.7 AAR не сохранился; rebuilt AAR не
выдавался за byte-identical из-за nondeterministic gomobile container.

## 4. Server/control outbound A/B

Endpoint names, addresses и credentials не сохранялись. Использовались
generation-scoped HMAC IDs.

- TROJAN A: example, YouTube, Telegram и Speedtest failed; h3 passed.
- TROJAN B: example passed, но YouTube, Telegram и Speedtest failed.
- тот же TROJAN C в разные моменты сначала failed, затем провёл YouTube h3.
- несколько VLESS controls провели YouTube; control D также провёл Telegram
  и загрузил Speedtest page.
- выбранный validation control выполнил полную Global matrix.

Это доказывает зависимость результата от endpoint/server route, но не
изолирует один фактор полностью: лучший устойчивый control использовал иной
protocol. Поэтому root cause — `PARTIALLY PROVEN`, а не `PROVEN`.

Server-side SSH/host diagnostics не выполнялись: в локальной задаче не было
безопасного административного канала к VPN endpoint. Работоспособность
endpoint не выводилась из одного `example.com 200`.

## 5. DNS A/B

Stage 2.7 Global DNS и Stage 2.8 Global DNS byte-identical в effective config:
`dns-remote`, тот же final и `independent_cache`. DNS events завершались до
failed TCP connection, а working control использовал ту же policy. Russia
Direct DNS в Global не применялся. Production DNS change не сделан.

## 6. FakeDNS A/B

FakeIP/FakeDNS declaration отсутствует и в Stage 2.7, и в Stage 2.8 effective
Global config. Случайное отключение mapping Stage 2.8 не подтверждено.
Production FakeDNS change не сделан.

## 7. IPv4 / IPv6 A/B

Controlled DNS возвращал A и AAAA, TUN содержал IPv4 и IPv6 routes, HTTP/3
работал. Доказательства IPv6 black hole, physical IPv6 leak или того, что
IPv4-only исправляет failure, не получено. Validation-only production-wide
IPv4 preference не применялась.

## 8. QUIC A/B

Отключение QUIC не тестировалось как production candidate, потому что:

- exact Stage 2.8 уже проводил h3 при failed TCP services;
- final validation дал 4 h3 из 5;
- exact Stage 2.9 production дал 5 h3 и 4 h2 fallback без failures.

UDP/443 не является общим failed path. Production QUIC не отключён.

## 9. Mux A/B

Mux options не различались между effective Stage 2.7/2.8 configs. Close
telemetry не показала deterministic mux-stream reset. Mux не отключался и не
менялся без доказательства.

## 10. MTU / PMTU

Фактический TUN MTU прочитан из Android LinkProperties: `1500`. Короткие
requests могли fail на одном endpoint, тогда как 10 MiB transfers проходили
на control. Это не соответствует доказанному PMTU black hole. Снижение MTU
не применялось.

## 11. Close owner / root cause

Для Stage 2.8 example.com получена полная корреляция:

```text
DNS REMOTE
route final -> VPN
TROJAN outbound selected
outbound stream established in 150-430 ms
0 application bytes
orderly EOF after about 1.2-1.5 s
closeOwner = OUTBOUND_OR_DESTINATION
errorClass = EOF_OR_ORDERLY_CLOSE
```

Это исключает DNS failure и close до установления proxy stream. Stage 2.7
compat воспроизвёл тот же close. На final exact production control основной
остаточный failure был иной: три из 20 parallel uploads завершились
`SocketTimeoutException` через 32–34 секунды.

Наиболее узкая подтверждённая классификация:

```text
ENDPOINT / SERVER-ROUTE / PEERING INSTABILITY
with residual throughput/time-varying degradation
```

Инициатора глубже remote VPN server против destination/CDN/middlebox без
server packet capture определить нельзя.

## 12. Production fix

Production data-plane code не менялся: один детерминированный клиентский
дефект не был доказан. Простая смена сервера не выдаётся за code fix. DNS,
FakeDNS, IPv6, QUIC, mux, MTU и selection policy оставлены без изменений.

Добавлены только validation capabilities:

- redacted effective-config export (`9ea10e4f`);
- connection-close correlation (`501179af`);
- bounded/privacy-hardened evidence (`002fa3f2`);
- bounded Cloudflare result extractor (`828d7ae9`).

Все hooks gated/tagged; production core собран без
`zeon_route_validation`. Отдельного root-cause fix commit нет, потому что его
создание противоречило бы критерию «one factor explains failure».

## 13. Global browser results

Validation control:

```text
YouTube: 5/5
Telegram: 5/5
Cloudflare Speedtest: 5/5 complete download/upload
```

Exact production candidate `828d7ae9`:

```text
YouTube: 5/5
Telegram: 5/5
Cloudflare Speedtest: 0/3 complete
```

В трёх production Speedtest captures main document был HTTP 200, download
начинался, но upload/final metrics не завершились в безопасном capture window.
Ни один такой run не засчитан как PASS.

## 14. HTTP/2 / HTTP/3

- YouTube main documents: h2 и h3;
- Telegram main documents: h2;
- HttpEngine exact production: 9/9 success, 5 h3 и 4 h2 fallback;
- положительный критерий минимум 3 h3 выполнен.

HTTP/3 работает, но сам по себе не исправляет failed Speedtest/parallel upload.

## 15. Speedtest and baseline transport

Exact production controlled probes:

| Probe | Результат |
|---|---:|
| HTTPS 64 KiB | 20/20 |
| 10 MiB download | 5/5 |
| 10 MiB upload | 5/5 |
| parallel download, concurrency 4 | 20/20, около 160 s |
| parallel upload, concurrency 4 | 17/20 |
| browser Speedtest complete | 0/3 |

Controlled transport подтверждает частичную работоспособность, но не заменяет
обязательный browser Speedtest. Исторический Stage 2 device report также
фиксировал Speedtest closes на более раннем immutable artifact; поэтому
утверждение «Stage 2.7 полностью работал для Speedtest» не доказано.

## 16. Lifecycle

Exact production APK:

```text
connect/stop: 20/20
restart: 10/10
HTTPS after every restart: 10/10
background/foreground: PASS
screen off 30 seconds: PASS
VPN remained VALIDATED: yes
process PID remained stable: yes
notification record present: yes
```

Automation misses, в которых Stop не был подтверждён, исключались и не
включались в 20 counted cycles. Wi-Fi ↔ cellular не выполнялся: безопасная
доступность мобильного data plane и отсутствие тарифицируемого трафика не были
подтверждены.

Final cleanup выполнялся после PIN keyguard через package-scoped force-stop,
без `pm clear` и без удаления приложения. После 15 секунд settling:

```text
VPN NetworkAgent: 0
TUN links: 0
foreground ServiceRecord: 0
ZEON notification records: 0
package process: 0
production FATAL EXCEPTION: 0
production ANR: 0
SIGSEGV / SIGABRT / Go panic / native panic: 0
```

## 17. Russia regression

Validation build, generation `1785504245493461`:

- Yandex → `zeon-ru-yandex`, DIRECT / DIRECT DNS;
- Wildberries → `zeon-ru-wildberries`, DIRECT / DIRECT DNS;
- Ozon, Gosuslugi, Sber, `.ru`, `.su`, `.xn--p1ai` →
  `zapret-ru-domains`, DIRECT / DIRECT DNS;
- `vk.com` → resolved IPv4 matched `zapret-ru-ip`, DIRECT.

Для IP-only cross-zone `vk.com` DNS был REMOTE до IP classification. Это
не новая Stage 2.9 регрессия, но буквально не удовлетворяет требованию
`DNS DIRECT` для каждого short-regression case. RU rule sets не менялись.

Exact production Russia browser sweep после required screen-off не был
выполнен: устройство перешло на PIN keyguard. PIN не обходился и не
угадывался. Поэтому строгий verdict `Russia regression: FAIL`.

## 18. Artifact hashes and installation

Production revision:
`828d7ae98665c6a7da3e0cf0a192ecdd12f9731e`.

Embedded trees:

```text
hiddify-core tree: 441e9e3dec906b9210669056d731e40b2a58945f
hiddify-sing-box tree: eaf737513f9f24619424d03e8f8a863b9ecabb70
```

| Artifact | SHA-256 |
|---|---|
| production core AAR | `f7ed6384ab761fd6eb5ffc8914beb100d372d7c65a52deb98ff719d1618fdee3` |
| production arm64 APK | `32783304543ec23732acb17355e454efa1d8e729c753b1db3fbb82f6b252bd74` |
| production AAB | `812bb46f5ce6d1c693649f171a922c42e156ee345004f291ad5ecbab18a96359` |
| installed base.apk | `32783304543ec23732acb17355e454efa1d8e729c753b1db3fbb82f6b252bd74` |

Version: `1.3.0 (103001)`. APK certificate SHA-256 matched Stage 2.8.
Установка выполнена `adb install -r -d`; `firstInstallTime` остался
`2026-07-29 23:13:48`.

Archive scan AAR/APK/AAB:

```text
production telemetry markers: 0
local RU rule-set markers: present
mutable remote RU-list URL: 0
```

Rule-set provenance не изменён:

```text
manifest: 17f10be4b391d753117c49445852bcc277773c9c98d49228adb062ca2fcecd92
zapret-ru-domains.srs: a39faeb4a4c894a2ce665b8919322cee626f61dd12c63a63736fcf8b0a433053
zapret-ru-ip.srs: 1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b
```

## 19. Rollback

Сохранены локально:

- exact Stage 2.8 installed APK;
- Stage 2.7 APK and compatibility core evidence;
- Stage 2.8 local RU rule sets;
- Stage 2.9 validation and production artifacts.

Validation commits можно откатывать независимо, начиная с последнего:

```text
git revert 828d7ae9
git revert 002fa3f2
git revert 501179af
git revert 9ea10e4f
```

Эти revert не удаляют RU rule sets, Yandex/Wildberries DIRECT,
`VpnSessionSnapshot`, notification synchronization или `Mobile.close()` fix.
Production Global data-plane fix отсутствует, поэтому отдельного production
rollback commit нет.

## 20. Remaining limitations

1. Remote endpoint packet capture/server diagnostics недоступны.
2. Same-protocol полностью рабочий TROJAN control не был стабильно получен.
3. Exact Stage 2.7 AAR не сохранился byte-identical; compatibility build
   изменил только требуемый generation ABI.
4. IPv4-only, QUIC-disabled, mux-disabled и reduced-MTU production variants не
   строились, потому что evidence не оправдывал такие изменения.
5. Full production Speedtest 5/5 не выполнен; production result остаётся FAIL.
6. Exact-production Russia regression заблокирован PIN keyguard после
   screen-off; PIN не обходился.
7. Cellular handoff не выполнялся без подтверждения безопасной/нетарифицируемой
   мобильной сети.

## Evidence index

```text
out/stage2-9/global-effective-config-stage27-redacted.json
out/stage2-9/global-effective-config-stage28-redacted.json
out/stage2-9/global-config-diff.txt
out/stage2-9/global-transport-matrix.csv
out/stage2-9/global-server-ab.csv
out/stage2-9/global-one-factor-ab.csv
out/stage2-9/connection-close-evidence.csv
out/stage2-9/global-browser-results.csv
out/stage2-9/russia-regression.csv
out/stage2-9/SHA256SUMS-redacted.txt
```
