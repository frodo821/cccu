import CoreGraphics
import Foundation

/// ポインタの動かし方。
///  human (既定): フィッツの法則で所要時間を決め、最小ジャークの速度プロファイルと軽い曲線で移動する。
///                ホバー状態を前提にした UI や、軌跡を見る検知、ドラッグ処理が瞬間移動 (ワープ) で壊れるのを避ける
///  warp: 目標点へ 1 回の mouseMoved で移動する (従来の挙動)
public enum PointerMode: String { case human, warp }
public var pointerMode: PointerMode =
    PointerMode(rawValue: ProcessInfo.processInfo.environment["CCCU_POINTER"] ?? "") ?? .human

/// 操作後にカーソルを元の位置へ戻すか。既定は戻さない:
/// 見ている人にとってカーソルは視線の先 (操作した場所) にある方が自然で、見ていない人はどのみち探すことになる。
/// 戻す動作自体も瞬間移動で、ユーザーがその間にマウスを動かしていれば奪い合いになる (CCCU_POINTER_RESTORE=always で有効化)
public var restorePointerAfterAction = ProcessInfo.processInfo.environment["CCCU_POINTER_RESTORE"] == "always"

public enum Fitts {
    /// 所要時間 (秒)。a, b はマウス操作の典型値。極端に短い/長い移動はクランプする
    public static let a = 0.05, b = 0.12
    public static func duration(distance: CGFloat, targetWidth: CGFloat) -> TimeInterval {
        let w = Double(max(targetWidth, 4))
        let index = log2(Double(distance) / w + 1)          // 難易度指標 (bit)
        return min(max(a + b * index, 0.08), 0.6)
    }

    /// 最小ジャーク (minimum-jerk) の位置プロファイル s(t) ∈ [0,1]
    public static func minimumJerk(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 10 * pow(t, 3) - 15 * pow(t, 4) + 6 * pow(t, 5)
    }

    /// from → to の軌跡。2 次ベジェで進行方向に対して垂直に少し膨らませる (人の手は直線に動かない)。
    /// 戻り値は (位置, 開始からの経過秒)。先頭は from、末尾は to に一致する
    public static func path(from: CGPoint, to: CGPoint, duration: TimeInterval, rate: Double = 120, rng: inout SystemRandomNumberGenerator) -> [(CGPoint, TimeInterval)] {
        let dx = to.x - from.x, dy = to.y - from.y
        let dist = hypot(dx, dy)
        guard dist > 0.5 else { return [(to, 0)] }
        // 曲率: 距離の 3〜10% だけ横に膨らむ。向きはランダム
        let bulge = dist * CGFloat.random(in: 0.03...0.10, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        let nx = -dy / dist, ny = dx / dist                 // 進行方向に垂直な単位ベクトル
        let ctrl = CGPoint(x: (from.x + to.x) / 2 + nx * bulge, y: (from.y + to.y) / 2 + ny * bulge)
        let n = max(Int(duration * rate), 2)
        var out: [(CGPoint, TimeInterval)] = []
        for i in 0...n {
            let t = Double(i) / Double(n)
            let s = CGFloat(minimumJerk(t))
            let u = 1 - s
            let p = CGPoint(x: u * u * from.x + 2 * u * s * ctrl.x + s * s * to.x,
                            y: u * u * from.y + 2 * u * s * ctrl.y + s * s * to.y)
            out.append((p, t * duration))
        }
        out[out.count - 1] = (to, duration)
        return out
    }

    /// 着地点: 中心付近に小さな散らばり (目標の 15% 以内)。極小の目標は中心そのまま
    public static func landing(center: CGPoint, size: CGSize?, rng: inout SystemRandomNumberGenerator) -> CGPoint {
        guard let size = size, size.width > 8, size.height > 8 else { return center }
        let rx = size.width * 0.15, ry = size.height * 0.15
        return CGPoint(x: center.x + CGFloat.random(in: -rx...rx, using: &rng), y: center.y + CGFloat.random(in: -ry...ry, using: &rng))
    }

    /// スクロール量を、減速する一連の差分に分割する (合計は total に一致)
    public static func scrollSteps(total: Int) -> [Int] {
        guard total != 0 else { return [] }
        let magnitude = abs(total)
        let n = min(max(magnitude / 24, 4), 28)
        // 重み: 立ち上がりが速く、後半はゆっくり (1 - s(t)) 型
        let weights = (0..<n).map { 1.0 - minimumJerk(Double($0) / Double(n)) + 0.05 }
        let sum = weights.reduce(0, +)
        var steps = weights.map { Int((Double(magnitude) * $0 / sum).rounded(.down)) }
        let remainder = magnitude - steps.reduce(0, +)
        for i in 0..<remainder { steps[i % n] += 1 }   // 端数を前から配る
        return steps.map { total < 0 ? -$0 : $0 }.filter { $0 != 0 }
    }
}
