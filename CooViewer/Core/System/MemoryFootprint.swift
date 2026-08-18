import Darwin
import Foundation

/// プロセスの実メモリ使用量(アクティビティ窓向け)。task_info の
/// TASK_VM_INFO から phys_footprint を読む(Activity Monitor の「メモリ」に近い)。
/// 取得できない場合は nil を返し、呼び出し側はその行を表示しない(捏造しない)
enum MemoryFootprint {
    nonisolated static func residentBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}
