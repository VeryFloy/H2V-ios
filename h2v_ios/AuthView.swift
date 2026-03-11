import SwiftUI

// MARK: - Auth Step

enum AuthStep {
    case email, otp, nickname
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
    @Published var resendSeconds = 0

    private var resendTimer: Timer?

    func cleanup() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    // MARK: Step 1: Send OTP

    func sendOtp(appState: AppState) {
        let em = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !em.isEmpty, !isLoading else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                try await APIClient.shared.sendOtp(email: em)
                self.step = .otp
                self.startResendTimer()
            } catch let e as NetworkError {
                self.errorMsg = e.localizedDescription
            } catch {
                self.errorMsg = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    // MARK: Step 2: Verify OTP

    func verifyOtp(appState: AppState) {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard c.count == 6, !isLoading else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                let data = try await APIClient.shared.verifyOtp(
                    email: self.email.trimmingCharacters(in: .whitespaces).lowercased(),
                    code: c
                )
                appState.signIn(user: data.user, tokens: data.tokens)
            } catch NetworkError.nicknameRequired {
                self.step = .nickname
                self.errorMsg = nil
            } catch let e as NetworkError {
                self.errorMsg = e.localizedDescription
            } catch {
                self.errorMsg = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    // MARK: Step 3: Set Nickname (new users only)

    func setNickname(appState: AppState) {
        let nick = nickname.trimmingCharacters(in: .whitespaces).lowercased()
        guard nick.count >= 5, !isLoading else {
            errorMsg = "Минимум 5 символов"
            return
        }
        let pattern = "^[a-zA-Z][a-zA-Z0-9.]{4,31}$"
        guard NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: nick) else {
            errorMsg = "Только a-z, 0-9, точка. Начинать с буквы (5-32 символа)"
            return
        }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                let data = try await APIClient.shared.verifyOtp(
                    email: self.email.trimmingCharacters(in: .whitespaces).lowercased(),
                    code: self.code.trimmingCharacters(in: .whitespaces),
                    nickname: nick
                )
                appState.signIn(user: data.user, tokens: data.tokens)
            } catch NetworkError.otpExpired {
                self.step = .otp
                self.code = ""
                self.errorMsg = "Код истёк — запроси новый"
            } catch let e as NetworkError {
                self.errorMsg = e.localizedDescription
            } catch {
                self.errorMsg = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    // MARK: Resend OTP

    func resendOtp() {
        guard resendSeconds == 0 else { return }
        let em = email.trimmingCharacters(in: .whitespaces).lowercased()
        Task {
            do {
                try await APIClient.shared.sendOtp(email: em)
                self.startResendTimer()
            } catch {}
        }
    }

    private func startResendTimer() {
        resendSeconds = 60
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                if self.resendSeconds > 0 {
                    self.resendSeconds -= 1
                } else {
                    t.invalidate()
                }
            }
        }
    }
}

// MARK: - AuthView

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AuthViewModel()
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            RadialGradient(
                colors: [Color(hex: "5E8CFF").opacity(0.07), .clear],
                center: .top, startRadius: 0, endRadius: 340
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 80)
                    logoSection
                    Spacer().frame(height: 44)

                    Group {
                        switch vm.step {
                        case .email:    emailStep
                        case .otp:      otpStep
                        case .nickname: nicknameStep
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: vm.step)

                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onDisappear { vm.cleanup() }
    }

    // MARK: Logo

    private var logoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(hex: "4A7CFF"), Color(hex: "7A4AFF")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 72, height: 72)
                    .shadow(color: Color(hex: "4A7CFF").opacity(0.35), radius: 24, x: 0, y: 8)
                Text("H")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
            }
            Text("H2V")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .tracking(-0.8)
        }
    }

    // MARK: Step 1 — Email

    private var emailStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Войти или зарегистрироваться")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Введи email — мы отправим код")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.38))
            }

            GlassInputField(
                label: "Email",
                text: $vm.email,
                keyboard: .emailAddress,
                autocap: .never
            )
            .focused($focused)
            .onSubmit { vm.sendOtp(appState: appState) }

            errorBanner

            AuthPrimaryButton(
                title: "Отправить код",
                loading: vm.isLoading,
                enabled: vm.email.contains("@")
            ) {
                focused = false
                vm.sendOtp(appState: appState)
            }
        }
    }

    // MARK: Step 2 — OTP Code

    private var otpStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Введи код из письма")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                VStack(spacing: 4) {
                    Text("Код отправлен на \(vm.email)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.38))
                    Button("Изменить email") {
                        vm.step = .email
                        vm.code = ""
                        vm.errorMsg = nil
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "5E8CFF"))
                }
            }

            OtpCodeField(code: $vm.code)
                .focused($focused)
                .onSubmit { vm.verifyOtp(appState: appState) }

            errorBanner

            AuthPrimaryButton(
                title: "Войти",
                loading: vm.isLoading,
                enabled: vm.code.count == 6
            ) {
                focused = false
                vm.verifyOtp(appState: appState)
            }

            Button {
                vm.resendOtp()
            } label: {
                Text(vm.resendSeconds > 0
                     ? "Повторить через \(vm.resendSeconds) с"
                     : "Отправить повторно")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        vm.resendSeconds > 0
                            ? Color.white.opacity(0.22)
                            : Color(hex: "5E8CFF")
                    )
            }
            .disabled(vm.resendSeconds > 0)
        }
    }

    // MARK: Step 3 — Nickname (new users only)

    private var nicknameStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Придумай никнейм")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("Это твой уникальный ID в H2V.\nТолько латиница, цифры и точка.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .multilineTextAlignment(.center)
            }

            GlassInputField(
                label: "Никнейм",
                text: $vm.nickname,
                autocap: .never
            )
            .focused($focused)
            .onSubmit { vm.setNickname(appState: appState) }

            errorBanner

            AuthPrimaryButton(
                title: "Создать аккаунт",
                loading: vm.isLoading,
                enabled: vm.nickname.count >= 5
            ) {
                focused = false
                vm.setNickname(appState: appState)
            }
        }
    }

    // MARK: Shared error banner

    @ViewBuilder
    private var errorBanner: some View {
        if let err = vm.errorMsg {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                Text(err)
                    .font(.system(size: 13))
            }
            .foregroundStyle(Color.dangerRed)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackground(cornerRadius: 10, opacity: 0.3)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.easeInOut(duration: 0.2), value: vm.errorMsg)
        }
    }
}

// MARK: - OTP Code Input Field

private struct OtpCodeField: View {
    @Binding var code: String

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .tracking(12)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue { code = filtered }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .glassBackground(cornerRadius: 16, opacity: 0.38)
        }
        .overlay(alignment: .trailing) {
            if !code.isEmpty {
                Button {
                    code = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textTertiary)
                        .padding(.trailing, 16)
                }
            }
        }
    }
}

// MARK: - Auth Primary Button

private struct AuthPrimaryButton: View {
    let title: String
    let loading: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if loading {
                    ProgressView().tint(.black)
                } else {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(enabled ? .black : Color.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                enabled
                    ? AnyShapeStyle(Color.white.opacity(0.92))
                    : AnyShapeStyle(Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(enabled ? 0 : 0.1), lineWidth: 0.5)
            }
            .shadow(color: .white.opacity(enabled ? 0.15 : 0), radius: 16, x: 0, y: 2)
        }
        .disabled(!enabled || loading)
        .animation(.easeInOut(duration: 0.18), value: enabled)
    }
}
