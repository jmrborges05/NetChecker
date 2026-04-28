import Foundation
import ObjectiveC

/// Inspects WebSocket traffic by swizzling URLSession.webSocketTask methods 
/// and the internal __NSURLSessionWebSocketTask message send/receive methods.
public final class WebSocketInspector {
    
    public static let shared = WebSocketInspector()
    
    private var isSwizzled = false
    private let swizzleLock = NSLock()
    
    /// Maps a URLSessionWebSocketTask (by its identifier) to a TrafficRecord UUID
    private var taskToRecordMap: [Int: UUID] = [:]
    private let mapLock = NSLock()
    
    private init() {}
    
    public func activate() {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        
        guard !isSwizzled else { return }
        swizzleURLSession()
        swizzleWebSocketTask()
        isSwizzled = true
    }
    
    public func deactivate() {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        
        guard isSwizzled else { return }
        // Currently we do not unswizzle block-based swizzling as it is complex to remove 
        // cleanly without storing the original IMPs. In a complete implementation, 
        // we'd store the original IMPs and restore them here.
        isSwizzled = false
    }
    
    internal func associate(task: URLSessionWebSocketTask, with recordId: UUID) {
        mapLock.lock()
        taskToRecordMap[task.taskIdentifier] = recordId
        mapLock.unlock()
    }
    
    internal func recordId(for task: URLSessionWebSocketTask) -> UUID? {
        mapLock.lock()
        defer { mapLock.unlock() }
        return taskToRecordMap[task.taskIdentifier]
    }
    
    internal func handleTaskCreated(_ task: URLSessionWebSocketTask, url: URL?) {
        guard isSwizzled, let requestURL = url ?? task.currentRequest?.url else { return }
        
        mapLock.lock()
        let existingId = taskToRecordMap[task.taskIdentifier]
        mapLock.unlock()
        
        if existingId != nil {
            // Record already exists for this task, ignore duplicate
            return
        }
        
        var request = URLRequest(url: requestURL)
        if let originalRequest = task.originalRequest {
            request = originalRequest
        }
        
        let record = TrafficRecord(from: request)
        Task { @MainActor in
            TrafficStore.shared.add(record)
        }
        
        associate(task: task, with: record.id)
    }
    
    internal func handleMessageSent(task: URLSessionWebSocketTask, message: AnyObject) {
        guard let recordId = recordId(for: task) else {
            return
        }
        
        let typeInt = message.value(forKey: "type") as? Int ?? 1
        let type: WebSocketMessage.MessageType = typeInt == 0 ? .data : .string
        let string = message.value(forKey: "string") as? String
        let data = message.value(forKey: "data") as? Data
        
        let wsMessage = WebSocketMessage(
            direction: .sent,
            type: type,
            stringData: string,
            binaryData: data
        )
        
        Task { @MainActor in
            TrafficStore.shared.addWebSocketMessage(id: recordId, message: wsMessage)
        }
    }
    
    internal func handleMessageReceived(task: URLSessionWebSocketTask, message: AnyObject) {
        guard let recordId = recordId(for: task) else { return }
        
        let typeInt = message.value(forKey: "type") as? Int ?? 1
        let type: WebSocketMessage.MessageType = typeInt == 0 ? .data : .string
        let string = message.value(forKey: "string") as? String
        let data = message.value(forKey: "data") as? Data
        
        let wsMessage = WebSocketMessage(
            direction: .received,
            type: type,
            stringData: string,
            binaryData: data
        )
        
        Task { @MainActor in
            TrafficStore.shared.addWebSocketMessage(id: recordId, message: wsMessage)
        }
    }
    
    // MARK: - Swizzling implementation
    
    private func swizzleURLSession() {
        // 1. webSocketTask(with: URL)
        let m1_sel = #selector(URLSession.webSocketTask(with:) as (URLSession) -> (URL) -> URLSessionWebSocketTask)
        let m1_orig = class_getInstanceMethod(URLSession.self, m1_sel)!
        let m1_origImp = method_getImplementation(m1_orig)
        typealias M1Func = @convention(c) (URLSession, Selector, URL) -> URLSessionWebSocketTask
        let m1_func = unsafeBitCast(m1_origImp, to: M1Func.self)
        
        let m1_block: @convention(block) (URLSession, URL) -> URLSessionWebSocketTask = { slf, url in
            let task = m1_func(slf, m1_sel, url)
            WebSocketInspector.shared.handleTaskCreated(task, url: url)
            return task
        }
        method_setImplementation(m1_orig, imp_implementationWithBlock(m1_block))
        
        // 2. webSocketTask(with: URL, protocols: [String])
        let m2_sel = #selector(URLSession.webSocketTask(with:protocols:) as (URLSession) -> (URL, [String]) -> URLSessionWebSocketTask)
        let m2_orig = class_getInstanceMethod(URLSession.self, m2_sel)!
        let m2_origImp = method_getImplementation(m2_orig)
        typealias M2Func = @convention(c) (URLSession, Selector, URL, [String]) -> URLSessionWebSocketTask
        let m2_func = unsafeBitCast(m2_origImp, to: M2Func.self)
        
        let m2_block: @convention(block) (URLSession, URL, [String]) -> URLSessionWebSocketTask = { slf, url, protocols in
            let task = m2_func(slf, m2_sel, url, protocols)
            WebSocketInspector.shared.handleTaskCreated(task, url: url)
            return task
        }
        method_setImplementation(m2_orig, imp_implementationWithBlock(m2_block))
        
        // 3. webSocketTask(with: URLRequest)
        let m3_sel = #selector(URLSession.webSocketTask(with:) as (URLSession) -> (URLRequest) -> URLSessionWebSocketTask)
        let m3_orig = class_getInstanceMethod(URLSession.self, m3_sel)!
        let m3_origImp = method_getImplementation(m3_orig)
        typealias M3Func = @convention(c) (URLSession, Selector, URLRequest) -> URLSessionWebSocketTask
        let m3_func = unsafeBitCast(m3_origImp, to: M3Func.self)
        
        let m3_block: @convention(block) (URLSession, URLRequest) -> URLSessionWebSocketTask = { slf, request in
            let task = m3_func(slf, m3_sel, request)
            WebSocketInspector.shared.handleTaskCreated(task, url: request.url)
            return task
        }
        method_setImplementation(m3_orig, imp_implementationWithBlock(m3_block))
    }
    
    private func swizzleWebSocketTask() {
        guard let cls = NSClassFromString("__NSURLSessionWebSocketTask") else { return }
        
        // sendMessage:completionHandler:
        let sendSel = NSSelectorFromString("sendMessage:completionHandler:")
        if let origSendMethod = class_getInstanceMethod(cls, sendSel) {
            let origSendImp = method_getImplementation(origSendMethod)
            typealias SendFunction = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
            let origSendFunc = unsafeBitCast(origSendImp, to: SendFunction.self)
            
            let sendBlock: @convention(block) (AnyObject, AnyObject, AnyObject) -> Void = { slf, message, completion in
                if WebSocketInspector.shared.isSwizzled, let task = slf as? URLSessionWebSocketTask {
                    WebSocketInspector.shared.handleMessageSent(task: task, message: message)
                }
                origSendFunc(slf, sendSel, message, completion)
            }
            method_setImplementation(origSendMethod, imp_implementationWithBlock(sendBlock))
        }
        
        // receiveMessageWithCompletionHandler:
        let recSel = NSSelectorFromString("receiveMessageWithCompletionHandler:")
        if let origRecMethod = class_getInstanceMethod(cls, recSel) {
            let origRecImp = method_getImplementation(origRecMethod)
            typealias HandlerBlock = @convention(block) (AnyObject?, NSError?) -> Void
            typealias RecFunction = @convention(c) (AnyObject, Selector, HandlerBlock) -> Void
            let origRecFunc = unsafeBitCast(origRecImp, to: RecFunction.self)
            
            let recBlock: @convention(block) (AnyObject, AnyObject) -> Void = { slf, rawHandler in
                let originalHandler = unsafeBitCast(rawHandler, to: HandlerBlock.self)
                let wrapped: HandlerBlock = { messageObj, error in
                    if WebSocketInspector.shared.isSwizzled, let task = slf as? URLSessionWebSocketTask {
                        if let msg = messageObj {
                            WebSocketInspector.shared.handleMessageReceived(task: task, message: msg)
                        }
                    }
                    originalHandler(messageObj, error)
                }
                origRecFunc(slf, recSel, wrapped)
            }
            let blockObj = unsafeBitCast(recBlock, to: AnyObject.self)
            method_setImplementation(origRecMethod, imp_implementationWithBlock(blockObj))
        }
    }
}
