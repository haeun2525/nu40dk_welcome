import CoreBluetooth
import Foundation

/// 보드와의 블루투스 연결. 도착을 알리고, 보드 상태를 받아온다.
///
/// **스캔하지 않고 재연결한다.**
///
/// 도착 감지는 비콘(`ArrivalManager`)이 맡고, 여기는 "알리기"만 한다. 그런데 백그라운드로
/// 깨어난 앱에게 스캔은 믿을 게 못 된다 — iOS는 백그라운드 스캔에서 서비스 UUID 지정을
/// 강제하는데, 이 보드의 광고 본문은 iBeacon 데이터로 꽉 차 있어서 서비스 UUID가
/// 스캔 응답에 있고, 백그라운드 스캔은 스캔 응답을 보지 않는다.
///
/// 그래서 **한 번 등록해두고 `retrievePeripherals(withIdentifiers:)`로 다시 붙는다.**
/// 이 경로는 스캔이 필요 없어서 백그라운드에서도 확실하게 동작한다.
/// 등록(최초 1회)만 앱을 열어놓고 스캔으로 한다.
final class BoardLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published private(set) var isConnected = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRegistered = false
    @Published private(set) var boardState: BoardIDs.BoardState?
    @Published private(set) var rssi: Int?
    @Published private(set) var statusText = "준비 중"

    private var central: CBCentralManager!
    private var board: CBPeripheral?
    private var cmdChar: CBCharacteristic?

    private let defaults = UserDefaults.standard
    private let savedIDKey = "welcome.boardPeripheralID"

    /// 아직 못 보낸 명령. 연결되는 즉시 나간다
    private var pending: BoardIDs.Command?
    private var pendingDone: ((Bool) -> Void)?
    private var pendingTimer: Timer?

    /// 명령을 이만큼 기다려도 못 보내면 실패로 친다.
    /// 무한정 기다리면 "보드에 알렸는지" 화면 표시가 영원히 확정되지 않는다
    private let sendTimeout: TimeInterval = 15

    private var savedID: UUID? {
        get { defaults.string(forKey: savedIDKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: savedIDKey); isRegistered = newValue != nil }
    }

    func prepare() {
        guard central == nil else { return }
        isRegistered = savedID != nil
        // 복원 식별자를 주면 시스템이 앱을 되살릴 때 블루투스 연결도 함께 돌려준다.
        // 없으면 백그라운드에서 앱이 재시작될 때 연결이 통째로 사라진다
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "nu40dk.welcome.central"]
        )
    }

    // MARK: 보내기

    func send(_ command: BoardIDs.Command, done: ((Bool) -> Void)? = nil) {
        prepare()

        if let char = cmdChar, let board, board.state == .connected {
            board.writeValue(Data([command.rawValue]), for: char, type: .withoutResponse)
            done?(true)
            return
        }

        // 아직 안 붙었다. 붙으면 보내도록 걸어두고 연결을 시작한다
        pending = command
        pendingDone = done
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: sendTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pending = nil
            self.pendingDone?(false)
            self.pendingDone = nil
        }
        connectIfPossible()
    }

    private func flushPending() {
        guard let command = pending, let char = cmdChar, let board else { return }
        board.writeValue(Data([command.rawValue]), for: char, type: .withoutResponse)
        pending = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingDone?(true)
        pendingDone = nil
    }

    // MARK: 연결

    private func connectIfPossible() {
        guard let central, central.state == .poweredOn else { return }
        guard let id = savedID else {
            statusText = "보드가 등록되지 않았습니다"
            return
        }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(known)
            // **연결에 타임아웃을 주지 않는다.** iOS가 요청을 계속 물고 있다가
            // 보드가 사거리에 들어오면 앱이 잠들어 있어도 붙여준다.
            // 출근길에 저절로 연결되는 게 이 성질 덕분이다
            central.connect(known, options: nil)
            statusText = "보드에 연결 중"
        } else {
            statusText = "등록된 보드를 못 찾았습니다 — 다시 등록해주세요"
        }
    }

    private func attach(_ peripheral: CBPeripheral) {
        board = peripheral
        peripheral.delegate = self
    }

    /// 최초 등록. 앱을 열어둔 채 보드 근처에서 한 번만 하면 된다
    func startRegistration() {
        prepare()
        guard let central, central.state == .poweredOn else {
            statusText = "블루투스가 꺼져 있습니다"
            return
        }
        isScanning = true
        statusText = "보드를 찾는 중…"
        // 포그라운드 스캔은 스캔 응답까지 본다. 그래서 여기서는 서비스 UUID로 찾을 수 있다
        central.scanForPeripherals(withServices: [BoardIDs.service], options: nil)

        // 오래 켜두면 배터리만 먹는다. 근처에 없으면 그만둔다
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.isScanning else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.board == nil { self.statusText = "보드를 못 찾았습니다 — 전원과 거리를 확인해주세요" }
        }
    }

    func forget() {
        if let board { central?.cancelPeripheralConnection(board) }
        board = nil
        cmdChar = nil
        savedID = nil
        isConnected = false
        boardState = nil
        statusText = "등록 해제됨"
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusText = savedID == nil ? "보드가 등록되지 않았습니다" : "대기 중"
            connectIfPossible()
        case .poweredOff:
            statusText = "블루투스가 꺼져 있습니다"
            isConnected = false
        case .unauthorized:
            statusText = "블루투스 권한이 없습니다"
        default:
            statusText = "블루투스 준비 중"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // 시스템이 앱을 되살리며 연결을 돌려줬다. 델리게이트를 다시 붙여야
        // 알림과 콜백이 이쪽으로 온다
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = restored.first {
            attach(first)
            isConnected = first.state == .connected
            if isConnected { first.discoverServices([BoardIDs.service]) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false

        savedID = peripheral.identifier
        attach(peripheral)
        central.connect(peripheral, options: nil)
        statusText = "보드 등록됨 — 연결 중"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        statusText = "보드 연결됨"
        peripheral.discoverServices([BoardIDs.service])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        cmdChar = nil
        rssi = nil
        statusText = "보드와 끊김"
        // 다시 붙여 둔다. 사거리 밖이면 iOS가 요청을 들고 기다리다가
        // 다음에 가까워질 때 자동으로 이어준다
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        statusText = "연결 실패 — 다시 시도합니다"
        central.connect(peripheral, options: nil)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BoardIDs.service }) else { return }
        peripheral.discoverCharacteristics([BoardIDs.status, BoardIDs.command], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == BoardIDs.command {
                cmdChar = char
            } else if char.uuid == BoardIDs.status {
                peripheral.setNotifyValue(true, for: char)
            }
        }
        // 붙기 전에 밀어둔 명령이 있으면 지금 나간다.
        // 도착 알림이 여기를 통해 전달되는 경우가 대부분이다
        flushPending()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BoardIDs.status,
              let data = characteristic.value, data.count >= 4 else { return }
        boardState = BoardIDs.BoardState(rawValue: data[0])
        rssi = Int(Int8(bitPattern: data[1]))
        if let boardState { statusText = "보드: \(boardState.label)" }
    }
}
