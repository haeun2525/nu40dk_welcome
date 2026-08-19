import CoreBluetooth
import Foundation

/// 펌웨어(`nu40dk_welcome.ino`)와 짝을 이루는 값들.
///
/// **여기 있는 UUID 중 하나라도 펌웨어와 어긋나면 조용히 실패한다.**
/// 비콘 UUID가 다르면 앱은 리전에 영영 못 들어가고(= 아무 일도 안 일어남),
/// 서비스 UUID가 다르면 보드를 못 찾는다. 둘 다 에러가 안 나서 원인 찾기가 오래 걸린다.
enum BoardIDs {

    /// iBeacon proximity UUID. 펌웨어의 `BEACON_UUID`와 같아야 한다.
    /// 6E753430-646B-4E55-C000-000000000001
    static let beaconUUID = UUID(uuidString: "6E753430-646B-4E55-C000-000000000001")!
    static let beaconMajor: UInt16 = 1
    static let beaconMinor: UInt16 = 1

    /// 리전 식별자. 아이폰 안에서만 쓰는 이름이라 아무 문자열이나 되지만,
    /// 바꾸면 이전에 등록된 리전과 별개로 취급되므로 그대로 두는 게 좋다.
    static let regionID = "nu40dk.welcome.desk"

    /// GATT. 도착을 보드에 알릴 때 쓴다.
    static let service = CBUUID(string: "6E753430-646B-4E55-C000-000000000010")
    static let status  = CBUUID(string: "6E753430-646B-4E55-C000-000000000011")
    static let command = CBUUID(string: "6E753430-646B-4E55-C000-000000000012")

    /// 펌웨어의 `Cmd` enum과 같은 값.
    enum Command: UInt8 {
        case auto    = 0x00
        case arrived = 0x01
        case quiet   = 0x02
        case away    = 0x03
    }

    /// 펌웨어의 `State` enum과 같은 값. status 알림의 0번 바이트로 온다.
    enum BoardState: UInt8 {
        case away    = 0
        case welcome = 1
        case present = 2

        var label: String {
            switch self {
            case .away:    return "부재"
            case .welcome: return "환영 중"
            case .present: return "자리에 있음"
            }
        }
    }
}
