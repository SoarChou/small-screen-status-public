import Cocoa
import Carbon

final class Hotkeys {
    let model: Model
    var references: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    static let numberCodes: [UInt32] = [18,19,20,21,23,22,26,28,25]
    static func operation(_ id: UInt32) -> (String, Int)? {
        if (101...109).contains(id) { return ("open", Int(id - 100)) }
        if (201...209).contains(id) { return ("pin", Int(id - 200)) }
        if id == 300 { return ("overview", 0) }
        if id == 301 { return ("tab", 0) }
        if id == 302 { return ("note", 0) }
        if id == 303 { return ("results", 0) }
        if id == 304 { return ("remind", 0) }
        if id == 305 { return ("timer", 0) }
        return nil
    }
    init(model: Model) { self.model = model }
    func start() {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr else { return status }
            let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            DispatchQueue.main.async { owner.perform(id) }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { model.hotkeyError = "全局快捷键监听未启动"; return }
        let base = UInt32(controlKey | optionKey | cmdKey)
        for (index, code) in Self.numberCodes.enumerated() {
            register(code, modifiers: base, id: UInt32(101 + index))
            register(code, modifiers: base | UInt32(shiftKey), id: UInt32(201 + index))
        }
        register(29, modifiers: base, id: 300) // 0: overview
        register(17, modifiers: base, id: 301) // T: tabs
        register(45, modifiers: base, id: 302) // N: quick note
        register(15, modifiers: base, id: 303) // R: results
        register(11, modifiers: base, id: 304) // B: reminder
        register(35, modifiers: base, id: 305) // P: pomodoro
        model.registeredHotkeys = references.count
    }
    func register(_ key: UInt32, modifiers: UInt32, id: UInt32) {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x53535354, id: id)
        let status = RegisterEventHotKey(key, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference = reference { references.append(reference) }
        else { model.hotkeyError = "部分快捷键被其他应用占用，请查看使用说明" }
    }
    func perform(_ id: UInt32) {
        guard let (action, position) = Self.operation(id) else { return }
        switch action {
        case "open": model.open(position: position)
        case "pin": model.pin(position: position)
        case "overview": model.clearPin(); model.tab = "tasks"; model.onShow?(); model.writeDiagnostics()
        case "note", "results", "remind", "timer": model.presentQuickPanel(action)
        default: model.toggleTab()
        }
    }
    func stop() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler = handler { RemoveEventHandler(handler) }
        handler = nil
    }
    deinit { stop() }
}
