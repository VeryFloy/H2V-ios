import SwiftUI

// MARK: - Create Group View

struct CreateGroupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    var onCreated: (Chat) -> Void

    @State private var step: GroupStep = .select
    @State private var searchText = ""
    @State private var searchResults: [User] = []
    @State private var selectedUsers: [User] = []
    @State private var groupName = ""
    @State private var isSearching = false
    @State private var isCreating = false
    @State private var error: String?

    enum GroupStep { case select, name }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                switch step {
                case .select: selectMembersStep
                case .name: setNameStep
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: step)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                if step == .name {
                    step = .select
                } else {
                    dismiss()
                }
            } label: {
                Text(step == .name ? "Назад" : "Отмена")
                    .font(.system(size: 15))
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            Text(step == .select ? "Новая группа" : "Имя группы")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.textPrimary)

            Spacer()

            if step == .select {
                Button { step = .name } label: {
                    Text("Далее")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(selectedUsers.isEmpty ? .textTertiary : .h2vAccent)
                }
                .disabled(selectedUsers.isEmpty)
            } else {
                Color.clear.frame(width: 60)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Select Members

    private var selectMembersStep: some View {
        VStack(spacing: 0) {
            if !selectedUsers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selectedUsers) { user in
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    AvatarView(url: user.avatarURL, initials: user.initials,
                                               size: 44, id: user.id)
                                    Button {
                                        selectedUsers.removeAll { $0.id == user.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.textSecondary)
                                            .background(Color.bgApp, in: Circle())
                                    }
                                    .offset(x: 4, y: -4)
                                }
                                Text(user.nickname)
                                    .font(.system(size: 10))
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(1)
                                    .frame(width: 50)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            SearchBar(text: $searchText, placeholder: "Найти пользователя...")
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .onChange(of: searchText) { _, q in search(q) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if isSearching {
                        ProgressView().padding(.top, 40)
                    } else {
                        ForEach(searchResults) { user in
                            let isSelected = selectedUsers.contains(where: { $0.id == user.id })
                            HStack(spacing: 12) {
                                AvatarView(url: user.avatarURL, initials: user.initials,
                                           size: 42, id: user.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.textPrimary)
                                    Text("@\(user.nickname)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.textSecondary)
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundColor(isSelected ? .h2vAccent : .textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelected {
                                    selectedUsers.removeAll { $0.id == user.id }
                                } else {
                                    selectedUsers.append(user)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Set Name

    private var setNameStep: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            VStack(spacing: 8) {
                Text("Как назвать группу?")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("\(selectedUsers.count) участников выбрано")
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }

            TextField("", text: $groupName,
                      prompt: Text("Имя группы").foregroundColor(.textTertiary))
                .foregroundColor(.textPrimary)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .inputStyle(radius: 12)
                .padding(.horizontal, 16)

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.danger)
            }

            AccentButton(title: "Создать группу", isLoading: isCreating,
                         disabled: groupName.trimmingCharacters(in: .whitespaces).isEmpty) {
                createGroup()
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    // MARK: - Actions

    private func search(_ q: String) {
        guard !q.isEmpty else { searchResults = []; return }
        isSearching = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            do { searchResults = try await APIClient.shared.searchUsers(query: q) } catch {}
            isSearching = false
        }
    }

    private func createGroup() {
        guard !groupName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isCreating = true
        error = nil
        Task {
            do {
                let chat = try await APIClient.shared.createGroup(
                    name: groupName,
                    memberIds: selectedUsers.map(\.id)
                )
                onCreated(chat)
            } catch let e as NetworkError {
                error = e.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}
