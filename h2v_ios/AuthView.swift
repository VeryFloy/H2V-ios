import SwiftUI

// MARK: - AuthViewModel

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isLogin = true
    @Published var email = ""
    @Published var password = ""
    @Published var nickname = ""
    @Published var isLoading = false
    @Published var errorMsg: String?

    var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (isLogin || !nickname.isEmpty)
    }

    func submit(appState: AppState) {
        guard canSubmit else { return }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                let data: AuthData
                if isLogin {
                    data = try await APIClient.shared.login(email: email, password: password)
                } else {
                    data = try await APIClient.shared.register(nickname: nickname, email: email, password: password)
                }
                TokenStorage.shared.save(tokens: data.tokens)
                appState.signIn(user: data.user, tokens: data.tokens)
            } catch let e as NetworkError {
                errorMsg = e.localizedDescription
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - AuthView

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AuthViewModel()
    @FocusState private var focusedField: Field?

    enum Field { case email, password, nickname }

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
                    formSection
                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
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
            VStack(spacing: 4) {
                Text("H2V")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .tracking(-0.8)
                Text(vm.isLogin ? "С возвращением" : "Создать аккаунт")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
    }

    // MARK: Form

    private var formSection: some View {
        VStack(spacing: 20) {
            modePicker

            VStack(spacing: 12) {
                GlassInputField(label: "Email", text: $vm.email, keyboard: .emailAddress, autocap: .never)
                    .focused($focusedField, equals: .email)

                if !vm.isLogin {
                    GlassInputField(label: "Никнейм", text: $vm.nickname)
                        .focused($focusedField, equals: .nickname)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                GlassInputField(label: "Пароль", text: $vm.password, secure: true)
                    .focused($focusedField, equals: .password)
            }

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
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            submitButton
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: vm.isLogin)
        .animation(.easeInOut(duration: 0.2), value: vm.errorMsg)
    }

    // MARK: Mode Picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeTab(title: "Войти",       active: vm.isLogin)  { vm.isLogin = true }
            modeTab(title: "Регистрация", active: !vm.isLogin) { vm.isLogin = false }
        }
        .padding(4)
        .glassBackground(cornerRadius: 14, opacity: 0.38)
    }

    private func modeTab(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white.opacity(0.9) : Color.white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.13))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                            }
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Submit Button

    private var submitButton: some View {
        Button {
            focusedField = nil
            vm.submit(appState: appState)
        } label: {
            ZStack {
                if vm.isLoading {
                    ProgressView().tint(.black)
                } else {
                    Text(vm.isLogin ? "Войти" : "Создать аккаунт")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(vm.canSubmit ? .black : Color.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                vm.canSubmit
                    ? AnyShapeStyle(Color.white.opacity(0.92))
                    : AnyShapeStyle(Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(vm.canSubmit ? 0 : 0.1), lineWidth: 0.5)
            }
            .shadow(color: .white.opacity(vm.canSubmit ? 0.15 : 0), radius: 16, x: 0, y: 2)
        }
        .disabled(!vm.canSubmit || vm.isLoading)
        .animation(.easeInOut(duration: 0.2), value: vm.canSubmit)
    }
}
