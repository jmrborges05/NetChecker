import Foundation
import NetCheckerTraffic

TrafficInterceptor.shared.startInterception(mode: .basic)

let url = URL(string: "wss://echo.websocket.events")!
let session = URLSession(configuration: .default)
let task = session.webSocketTask(with: url)

let group = DispatchGroup()
group.enter()

task.resume()

task.send(.string("Hello")) { error in
    if let error = error {
        print("Send error: \(error)")
    } else {
        print("Sent Hello")
    }
}

task.receive { result in
    switch result {
    case .success(let message):
        print("Received: \(message)")
    case .failure(let error):
        print("Receive error: \(error)")
    }
    group.leave()
}

group.wait()
