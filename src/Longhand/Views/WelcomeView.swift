import SwiftUI

/// Shown when no library is open: start from a folder on this Mac, or fetch a library that is
/// already backed up to GitHub.
struct WelcomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var gettingLibrary = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Text("/longhand")
                .font(Font(EditorFont.serif(46)))
                .foregroundStyle(Color(PaperTheme.ink))

            HStack(spacing: 10) {
                Button {
                    store.chooseLibrary()
                } label: {
                    choice(.folder, "Open a Folder…")
                }
                .buttonStyle(SquareButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .help("Choose or create a folder for your library")

                Button {
                    gettingLibrary = true
                } label: {
                    Text("Clone Repository…")
                        .frame(minWidth: 150)
                }
                .buttonStyle(SquareButtonStyle())
                .help("Clone a library from GitHub or any Git remote, with its history")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(PaperTheme.paper))
        .sheet(isPresented: $gettingLibrary) { GetLibrarySheet() }
    }

    private func choice(_ symbol: Symbol, _ title: String) -> some View {
        HStack(spacing: 7) {
            symbol.view(size: 13)
            Text(title)
        }
        .frame(minWidth: 150)
    }
}
