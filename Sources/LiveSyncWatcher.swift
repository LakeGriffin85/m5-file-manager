import Foundation

/// Poll snapshots off the UI thread; two equal samples debounce an editor's writes.
final class LiveSyncWatcher {
    var onStable: ((LiveSnapshot) -> Void)?
    var onError: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "org.m5filemanager.desktop.watch")
    private var timer: DispatchSourceTimer?
    init(root: URL) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var previous: LiveSnapshot?
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let next = try LiveSnapshot.read(root: root)
                if previous == next { DispatchQueue.main.async { [weak self] in self?.onStable?(next) } }
                previous = next
            } catch {
                DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            }
        }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }
}
