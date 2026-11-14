import SwiftUI

/// Four steps, each with a small moving picture: commit, push, branch, merge. Shown once
/// (owner, 2026-11-13; copy is the owner's), skippable, and again from Help.
struct GitIntro: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var still
    @State var step: Int = 0

    static let seenKey = "gitIntroSeen"

    private struct Step {
        let title: String
        let text: String
        let picture: Picture
    }
    enum Picture { case commit, push, branch, merge }

    private let steps: [Step] = [
        .init(title: "Commit", text: "Save a snapshot of everything you write, automatically. Or commit by hand, with a note.", picture: .commit),
        .init(title: "Push", text: "Back up your whole writing history to GitHub, another Git server or a drive. Or keep it all on this Mac.", picture: .push),
        .init(title: "Branch", text: "Try new ideas and directions, on a path of their own.", picture: .branch),
        .init(title: "Merge", text: "Fold a branch into your work, delete it, or keep it for later.", picture: .merge),
    ]

    var body: some View {
        let current = steps[step]
        VStack(alignment: .leading, spacing: 0) {
            GitPicture(picture: current.picture, still: still)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(Color(PaperTheme.well))
                .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
                .id(step)
            Text(current.title)
                .font(.headline)
                .foregroundStyle(Color(PaperTheme.ink))
                .padding(.top, 18)
            Text(current.text)
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.secondary))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .padding(.top, 6)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(steps.indices, id: \.self) { index in
                        rounded(1.5)
                            .fill(Color(index == step ? PaperTheme.ink : PaperTheme.controlBorder))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityLabel("Step \(step + 1) of \(steps.count)")
                Spacer()
                if step < steps.count - 1 {
                    Button("Skip") { finish() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(SquareButtonStyle())
                }
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(SquareButtonStyle())
                }
                Button(step == steps.count - 1 ? "Done" : "Next") {
                    if step == steps.count - 1 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareButtonStyle(primary: true))
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(PaperTheme.paper))
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }
}

/// The moving picture for a step: commits as small squares on a line, on a 2.6-second loop at
/// 8 frames a second; still (its last frame) when the Mac is set to reduce motion.
private struct GitPicture: View {
    let picture: GitIntro.Picture
    let still: Bool
    @State private var start = Date()
    private static let loop = 2.6
    private static let fps = 8.0

    var body: some View {
        if still {
            canvas(at: 0.75)
        } else {
            // Stop-motion, 8 frames a second (owner: "that cool slow fps look"): each frame is
            // held, so the pictures step rather than glide.
            // Counted from when the step appears (the picture is made anew for each step), so
            // every loop starts at its first frame.
            TimelineView(.periodic(from: start, by: 1.0 / Self.fps)) { context in
                let frames = (Self.loop * Self.fps).rounded()
                let frame = (max(0, context.date.timeIntervalSince(start)) * Self.fps).rounded(.down)
                    .truncatingRemainder(dividingBy: frames)
                canvas(at: frame / frames)
            }
        }
    }

    private func canvas(at t: Double) -> some View {
        ZStack {
            Canvas { context, size in draw(&context, size, t) }
            if picture == .push {
                HStack {
                    Symbol.mac.view(size: 30)
                    Spacer()
                    Symbol.server.view(size: 28)
                }
                .foregroundStyle(Color(PaperTheme.secondary))
                .padding(.horizontal, 44)
            }
        }
    }

    /// 0…1 over part of the loop, eased; 1 after it.
    private func ease(_ t: Double, from start: Double, to end: Double) -> Double {
        let x = min(max((t - start) / (end - start), 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let ink = Color(PaperTheme.ink), line = Color(PaperTheme.controlBorder), accent = Color(PaperTheme.accent)
        let mid = size.height / 2 + 6
        let left = size.width * 0.12, right = size.width * 0.88
        func commit(_ x: CGFloat, _ y: CGFloat, _ colour: Color, side: CGFloat = 12) {
            context.fill(Path(roundedRect: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side), cornerRadius: 2.5), with: .color(colour))
        }
        func stroke(_ path: Path, _ colour: Color, _ width: CGFloat = 2) {
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        let spot = { (i: Int) in left + (right - left) * CGFloat(i) / 6 }

        switch picture {
        case .commit:
            stroke(Path { $0.move(to: CGPoint(x: left, y: mid)); $0.addLine(to: CGPoint(x: right, y: mid)) }, line)
            for i in 0..<3 { commit(spot(i), mid, ink) }
            // A new commit settles onto the line.
            let drop = ease(t, from: 0.1, to: 0.5)
            commit(spot(3), mid - 46 * (1 - drop), ink.opacity(0.25 + 0.75 * drop))
        case .push:
            // A commit travels from this Mac to the remote.
            let x0 = size.width * 0.26, x1 = size.width * 0.74
            stroke(Path { $0.move(to: CGPoint(x: x0, y: size.height / 2)); $0.addLine(to: CGPoint(x: x1, y: size.height / 2)) },
                   line, 1.5)
            let go = ease(t, from: 0.05, to: 0.7)
            commit(x0 + (x1 - x0) * go, size.height / 2, ink, side: 10)
        case .branch:
            stroke(Path { $0.move(to: CGPoint(x: left, y: mid + 18)); $0.addLine(to: CGPoint(x: right, y: mid + 18)) }, line)
            for i in [0, 1, 2, 4, 5] { commit(spot(i), mid + 18, ink) }
            // A path leaves the line and grows; a commit appears at its end.
            let grow = ease(t, from: 0.05, to: 0.55)
            let start = CGPoint(x: spot(2), y: mid + 18), end = CGPoint(x: spot(5), y: mid - 26)
            let tip = CGPoint(x: start.x + (end.x - start.x) * grow, y: start.y + (end.y - start.y) * grow)
            stroke(Path { $0.move(to: start); $0.addLine(to: tip) }, accent)
            if grow > 0.98 { commit(end.x, end.y, accent) }
            if grow > 0.5 { commit(start.x + (end.x - start.x) * 0.5, start.y + (end.y - start.y) * 0.5, accent) }
        case .merge:
            stroke(Path { $0.move(to: CGPoint(x: left, y: mid + 18)); $0.addLine(to: CGPoint(x: right, y: mid + 18)) }, line)
            for i in [0, 1, 2, 3] { commit(spot(i), mid + 18, ink) }
            // The branch rejoins the line, and the meeting commit lands.
            let a = CGPoint(x: spot(1), y: mid + 18), b = CGPoint(x: spot(2) + 10, y: mid - 26),
                c = CGPoint(x: spot(4) - 6, y: mid - 26), d = CGPoint(x: spot(5), y: mid + 18)
            stroke(Path { $0.move(to: a); $0.addLine(to: b); $0.addLine(to: c) }, accent)
            commit(b.x, b.y, accent)
            commit(c.x, c.y, accent)
            let join = ease(t, from: 0.1, to: 0.55)
            let tip = CGPoint(x: c.x + (d.x - c.x) * join, y: c.y + (d.y - c.y) * join)
            stroke(Path { $0.move(to: c); $0.addLine(to: tip) }, accent)
            if join > 0.98 { commit(d.x, d.y, ink, side: 14) }
        }
    }
}
