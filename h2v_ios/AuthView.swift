import SwiftUI

// MARK: - Auth Step

enum AuthStep {
    case email
    case code
    case nickname
}

// MARK: - AuthViewModel

@MainActor
class AuthViewModel: ObservableObject {
    @Published var step: AuthStep = .email
    @Published var email = ""
    @Published var code = ""
    @Published var nickname = ""
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var resendTimer = 0

    private var timerTask: Task<Void, Never>?

    var canSendOtp: Bool { isValidEmail && !isLoading }
    var canVerify: Bool { code.count == 6 && !isLoading }
    var canSetNick: Bool { isValidNickname && !isLoading }

    private var isValidEmail: Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    private var isValidNickname: Bool {
        let pattern = #"^[a-zA-Z][a-zA-Z0-9.]{4,31}$"#
        return nickname.range(of: pattern, options: .regularExpression) != nil
    }

    func sendOtp() {
        guard canSendOtp else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                _ = try await APIClient.shared.sendOtp(email: email)
                step = .code
                startResendTimer()
            } catch let e as NetworkError {
                errorMsg = e.localizedDescription
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }

    func verify(appState: AppState) {
        guard canVerify else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                let data = try await APIClient.shared.verifyOtp(email: email, code: code)
                if data.isNewUser == true {
                    step = .nickname
                } else {
                    appState.signIn(user: data.user)
                }
            } catch let e as NetworkError {
                errorMsg = e.localizedDescription
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }

    func setNickname(appState: AppState) {
        guard canSetNick else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                let data = try await APIClient.shared.verifyOtp(email: email, code: code, nickname: nickname)
                appState.signIn(user: data.user)
            } catch let e as NetworkError {
                errorMsg = e.localizedDescription
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }

    func resendOtp() {
        guard resendTimer == 0 else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                _ = try await APIClient.shared.sendOtp(email: email)
                startResendTimer()
            } catch let e as NetworkError {
                errorMsg = e.localizedDescription
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }

    func goBack() {
        errorMsg = nil
        switch step {
        case .code: step = .email; code = ""
        case .nickname: step = .code; nickname = ""
        default: break
        }
    }

    private func startResendTimer() {
        timerTask?.cancel()
        resendTimer = 60
        timerTask = Task {
            while resendTimer > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                resendTimer -= 1
            }
        }
    }
}

// MARK: - AuthView

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AuthViewModel()

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            RadialGradient(
                colors: [Color.h2vAccent.opacity(0.08), .clear],
                center: .top, startRadius: 0, endRadius: 400
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 80)
                    logoSection
                    Spacer().frame(height: 40)

                    switch vm.step {
                    case .email:    emailStep
                    case .code:     codeStep
                    case .nickname: nicknameStep
                    }

                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.step)
    }

    // MARK: - Logo

    private var logoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient.accentGradient)
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.h2vAccent.opacity(0.35), radius: 24, y: 8)
                Text("H")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(.white)
            }
            Text("H2V")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.h2vAccent)
        }
    }

    // MARK: - Email Step

    private var emailStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Войти в H2V")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("Введи email — пришлём код")
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }

            VStack(spacing: 12) {
                inputField(text: $vm.email, placeholder: "Email", keyboard: .emailAddress)
                errorView
            }

            AccentButton(title: "Получить код", isLoading: vm.isLoading, disabled: !vm.canSendOtp) {
                vm.sendOtp()
            }
        }
        .cardBackground(radius: 20)
        .padding(.horizontal, 2)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
    }

    // MARK: - Code Step

    private var codeStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Введи код")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
                HStack(spacing: 4) {
                    Text("Отправили на")
                        .font(.system(size: 13))
                        .foregroundColor(.textSecondary)
                    Text(vm.email)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.h2vAccent)
                    Button("изменить") { vm.goBack() }
                        .font(.system(size: 13))
                        .foregroundColor(.textLink)
                }
            }

            VStack(spacing: 12) {
                codeInput
                errorView
            }

            AccentButton(title: "Войти", isLoading: vm.isLoading, disabled: !vm.canVerify) {
                vm.verify(appState: appState)
            }

            resendButton
        }
        .cardBackground(radius: 20)
        .padding(.horizontal, 2)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
    }

    // MARK: - Nickname Step

    private var nicknameStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Придумай юзернейм")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("Мин. 5 символов: латинские буквы, цифры и точки")
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                inputField(text: $vm.nickname, placeholder: "username")
                errorView
            }

            AccentButton(title: "Готово", isLoading: vm.isLoading, disabled: !vm.canSetNick) {
                vm.setNickname(appState: appState)
            }
        }
        .cardBackground(radius: 20)
        .padding(.horizontal, 2)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
    }

    // MARK: - Helpers

    private func inputField(text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text,
                  prompt: Text(placeholder).foregroundColor(.textTertiary))
            .foregroundColor(.textPrimary)
            .font(.system(size: 15))
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .inputStyle(radius: 10)
    }

    private var codeInput: some View {
        TextField("", text: $vm.code,
                  prompt: Text("000000").foregroundColor(.textTertiary))
            .foregroundColor(.textPrimary)
            .font(.system(size: 28, weight: .bold, design: .monospaced))
            .tracking(10)
            .multilineTextAlignment(.center)
            .keyboardType(.numberPad)
            .onChange(of: vm.code) { _, newVal in
                if newVal.count > 6 { vm.code = String(newVal.prefix(6)) }
                vm.code = newVal.filter(\.isNumber)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .inputStyle(radius: 10)
    }

    @ViewBuilder
    private var errorView: some View {
        if let err = vm.errorMsg {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                Text(err).font(.system(size: 12))
            }
            .foregroundColor(.danger)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private var resendButton: some View {
        Group {
            if vm.resendTimer > 0 {
                Text("Повторить через \(vm.resendTimer)с")
                    .font(.system(size: 13))
                    .foregroundColor(.textTertiary)
            } else {
                Button("Отправить снова") { vm.resendOtp() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.h2vAccent)
            }
        }
    }
}
