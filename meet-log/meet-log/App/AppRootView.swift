import SwiftUI

struct AppRootView: View {
    enum Destination {
        case recorder
        case library
    }

    @State private var destination: Destination = .recorder

    var body: some View {
        Group {
            switch destination {
            case .recorder:
                ZStack(alignment: .topTrailing) {
                    RecorderView()

                    Button {
                        destination = .library
                    } label: {
                        Image(systemName: "books.vertical")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Open Library")
                    .padding(14)
                }
                .frame(width: 420, height: 680)
            case .library:
                LibraryView {
                    destination = .recorder
                }
            }
        }
    }
}
