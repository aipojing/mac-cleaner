import Foundation

/// 实时大文件快照的限频发布器：首项立即发布，间隔内的更新只保留最新
/// 待发快照，`finish` 无条件发送最终快照。时钟注入保证测试确定性。
struct LargeFileUpdatePublisher<Value> {
    let minimumInterval: TimeInterval
    let now: () -> TimeInterval
    let deliver: (Value) -> Void
    private var lastDeliveryTime: TimeInterval?
    private var pending: Value?

    init(
        minimumInterval: TimeInterval,
        now: @escaping () -> TimeInterval,
        deliver: @escaping (Value) -> Void
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.deliver = deliver
    }

    mutating func submit(_ value: Value) {
        let currentTime = now()
        guard let lastDeliveryTime,
              currentTime - lastDeliveryTime < minimumInterval
        else {
            pending = nil
            self.lastDeliveryTime = currentTime
            deliver(value)
            return
        }
        pending = value
    }

    mutating func finish(_ value: Value) {
        pending = nil
        lastDeliveryTime = now()
        deliver(value)
    }
}
