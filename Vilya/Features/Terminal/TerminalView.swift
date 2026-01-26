import SwiftUI

struct CommandTerminalView: View {
    var session: TerminalSession
    @Environment(AppState.self) var appState
    @State private var viewModel = TerminalViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showToolbar = true

    var body: some View {
        VStack(spacing: 0) {
            TerminalContentView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showToolbar {
                TerminalToolbar(viewModel: viewModel)
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Constants.Colors.terminalBackground.ignoresSafeArea())
        .navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Constants.Colors.terminalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { viewModel.sendCtrlC() } label: { Label("Send Ctrl+C", systemImage: "xmark.circle") }
                    Button { viewModel.clearScreen() } label: { Label("Clear Screen", systemImage: "trash") }
                    Divider()
                    Button { showToolbar.toggle() } label: { Label(showToolbar ? "Hide Toolbar" : "Show Toolbar", systemImage: "keyboard") }
                    Divider()
                    Button(role: .destructive) { viewModel.disconnect(); dismiss() } label: { Label("Disconnect", systemImage: "xmark.circle.fill") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            viewModel.setSSHService(appState.sshService)
            viewModel.attachToSession(session)
        }
        .onDisappear { viewModel.detach() }
    }
}

struct TerminalContentView: View {
    var viewModel: TerminalViewModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Constants.Colors.terminalBackground
            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.terminalOutput)
                        .font(.system(size: viewModel.fontSize, design: .monospaced))
                        .foregroundColor(Constants.Colors.terminalForeground)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .onChange(of: viewModel.terminalOutput) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            TerminalInputField(viewModel: viewModel).frame(width: 1, height: 1).opacity(0.01)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.focus() }
    }
}

struct TerminalInputField: UIViewRepresentable {
    var viewModel: TerminalViewModel
    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(); tf.delegate = context.coordinator
        tf.autocorrectionType = .no; tf.autocapitalizationType = .none; tf.keyboardType = .asciiCapable; tf.keyboardAppearance = .dark
        tf.text = " " // Keep a space so backspace works
        viewModel.inputField = tf; return tf
    }
    func updateUIView(_ uiView: UITextField, context: Context) {
        // Keep at least one character so backspace can be detected
        if uiView.text?.isEmpty ?? true {
            uiView.text = " "
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }
    class Coordinator: NSObject, UITextFieldDelegate {
        let viewModel: TerminalViewModel
        init(viewModel: TerminalViewModel) { self.viewModel = viewModel }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                // Backspace pressed
                viewModel.sendInput("\u{7F}")
            } else {
                viewModel.sendInput(string)
            }
            // Keep a space in the field
            textField.text = " "
            return false
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { viewModel.sendInput("\n"); return false }
    }
}

struct TerminalToolbar: View {
    var viewModel: TerminalViewModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolbarButton(icon: "keyboard.chevron.compact.down", action: viewModel.hideKeyboard)
                Divider().frame(height: 30)
                ToolbarButton(label: "Tab", action: viewModel.sendTab)
                ToolbarButton(label: "Ctrl", isToggle: true, isActive: Binding(get: { viewModel.ctrlPressed }, set: { viewModel.ctrlPressed = $0 }))
                Divider().frame(height: 30)
                ToolbarButton(icon: "arrow.up", action: viewModel.sendArrowUp)
                ToolbarButton(icon: "arrow.down", action: viewModel.sendArrowDown)
                Divider().frame(height: 30)
                ToolbarButton(label: "Ctrl+C", action: viewModel.sendCtrlC)
                ToolbarButton(label: "Clear", action: viewModel.clearScreen)
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.background(Color(.secondarySystemBackground))
    }
}

struct ToolbarButton: View {
    var label: String?; var icon: String?; var isToggle = false; var isActive: Binding<Bool>?; var action: (() -> Void)?
    var body: some View {
        Button {
            if isToggle, let isActive = isActive { isActive.wrappedValue.toggle() } else { action?() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Group {
                if let icon = icon { Image(systemName: icon).font(.system(size: 14, weight: .medium)) }
                else if let label = label { Text(label).font(.system(size: 12, weight: .medium, design: .monospaced)) }
            }
            .foregroundColor(isToggle && isActive?.wrappedValue == true ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(isToggle && isActive?.wrappedValue == true ? Color.accentColor : Color(.tertiarySystemBackground)))
        }
    }
}

#Preview { NavigationStack { CommandTerminalView(session: TerminalSession(serverId: UUID(), name: "Test")) } }
