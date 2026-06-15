# LAN Online Trials — Two-Device Manual Test Plan
## P2P v1.3 | 2026-06-15

> **Prerequisite:** Both devices on the same Wi-Fi LAN. App version includes P2P v1.2 (Shared Events) + v1.3 (Diagnostics/Ping).

---

## Devices

| Role | Device | Notes |
|------|--------|-------|
| HOST | Mac A  | Creates session, becomes pilot |
| CLIENT | Mac B | Joins as pilot or spectator |

---

## Phase 1 — LAN Lobby

### 1.1 Host creates session
- [ ] Mac A: открыть Мульти-испытания → LAN → ввести имя → нажать **Создать LAN-сессию**
- [ ] Панель «Сессия» появляется, статус: **HOSTING**
- [ ] В строке «Мой IP» виден корректный IPv4-адрес Wi-Fi (не 127.x, не 169.254.x)
- [ ] Чеклист: Сессия активна ✓, Участников: 1 ✓, Фаза: lobby ✓, Транспорт: OK ✓

### 1.2 Client joins
- [ ] Mac B: вписать IP Mac A и порт → нажать **Подключиться**
- [ ] Mac B: статус → **CONNECTED**, виден локальный участник + хост в списке
- [ ] Mac A: список участников пополнился Mac B, участников: 2

### 1.3 Ping test
- [ ] Mac B: нажать **Тест пинг** — поле RTT заполняется (< 5 ms в LAN)
- [ ] Кнопка недоступна для хоста (хост = сервер, не имеет смысла пинговать себя)

---

## Phase 2 — Trial Launch

### 2.1 Launch
- [ ] Mac A (HOST): нажать **Запустить испытание**
- [ ] Оба устройства: переходят в симуляцию (окно закрывается, открывается вьюпорт)
- [ ] `LANSessionViewModel` НЕ пересоздаётся (session continues through handoff)

### 2.2 Overlay verification
- [ ] Tab (удерживать): открывается оверлей LAN TRIAL
- [ ] Authority: **Distributed Object**, Local auth: **UAV <ID>**, World auth: **host (local)** (только на Mac A)
- [ ] Participants: 2, Vehicles: 2 (если оба пилоты)
- [ ] Snapshot: 10 Hz

---

## Phase 3 — Snapshot Replication

### 3.1 Ghost visibility
- [ ] Mac A: видит ghost-дрон (синий, полупрозрачный) в точке спавна Mac B
- [ ] Mac B: видит ghost-дрон Mac A

### 3.2 Ghost movement
- [ ] Mac B: взлететь, двигаться вперёд
- [ ] Mac A: ghost двигается с задержкой ≤ 200 ms
- [ ] Диагностика (Tab): RX > 0 (входящие snapshots), GHOSTS: 1

### 3.3 Stale detection
- [ ] Mac B: закрыть/свернуть приложение (разорвать соединение)
- [ ] Mac A: через ~2 секунды ghost исчезает (STALE счётчик > 0), затем ghost node убирается
- [ ] Диагностика: STALE: 1

---

## Phase 4 — Shared Events

### 4.1 Collision detection
- [ ] Оба: взлететь, сблизиться вплотную (< 1.2m) на скорости ≥ 2 m/s
- [ ] Инициатор события (owner): Events секция оверлея показывает **VEHICLECOLLISION → DAMAGED/DISABLED/CRASHED**
- [ ] Второй участник: тот же event, применён к обоим (damageState)
- [ ] Поврежденный UAV: ghost меняет прозрачность + метка на ghost node

### 4.2 Control gate
- [ ] После DISABLED/CRASHED: управление UAV заблокировано (`canControlLocalVehicle = false`)
- [ ] Overlay показывает **LOCAL UAV DISABLED / CRASHED**
- [ ] Дрон дезармируется автоматически

### 4.3 Deduplication
- [ ] Столкновение не дублируется: второе событие для той же пары через < 2s игнорируется

---

## Phase 5 — Diagnostics Panel

- [ ] TX = количество отправленных snapshot-пакетов (только на пилоте)
- [ ] RX = количество полученных snapshot-пакетов
- [ ] EVT = количество полученных shared events
- [ ] PING = RTT в мс (только если пинг был выполнен из лобби)
- [ ] GHOSTS = количество видимых ghost nodes

---

## Phase 6 — Trial End & Cleanup

### 6.1 Host ends trial
- [ ] Mac A (Tab-оверлей): нажать **Завершить испытание**
- [ ] Mac B: оверлей показывает **ENDED**, управление UAV блокируется
- [ ] Оба: нажать **Выйти** → симуляция закрывается

### 6.2 Rejoin flow
- [ ] Оба вернулись на стартовый экран
- [ ] Mac A: можно создать новую сессию; Mac B: можно подключиться снова
- [ ] `onlineDiagnostics` сброшен (TX/RX = 0 в новой сессии)

---

## Known Limitations (v1.3)

- Terrain collision в одиночной симуляции не реплицируется
- Payload events не реализованы (kind = payloadReleased не обрабатывается)
- Rollback/reconciliation отсутствует намеренно (Distributed Authority)
- Пинг-кнопка доступна только клиенту — хост не нуждается в RTT к себе
