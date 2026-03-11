import SwiftUI

// MARK: - CreateGroupView

struct CreateGroupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Chat) -> Void

    @State private var groupName = ""
    @State private var searchText = ""
    @State private var foundUsers: [User] = []
    @State private var selectedUsers: [User] = []
    @State private var isSearching = false
    @State private var isCreating = false
    @State private var errorMsg: String?
    @State private var searchTask: Task<Void, Never>?

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespaces).isEmpty && !selectedUsers.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Group name input
                        groupNameSection

                        // Selected members chips
                        if !selectedUsers.isEmpty {
                            selectedChips
                        }

                        // Search
                        searchSection

                        // Results
                        if isSearching {
                            ProgressView()
                                .tint(Color.textSecondary)
                                .padding(.top, 32)
                        } else {
                            userResults
                        }

                        if let err = errorMsg {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.dangerRed)
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                        }

                        Spacer().frame(height: 100)
                    }
                }
                .scrollIndicators(.hidden)

                // Create button floating at bottom
                VStack {
                    Spacer()
                    createButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Новая группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }

    // MARK: Sections

    private var groupNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Название группы")
                .padding(.horizontal, 20)
                .padding(.top, 20)

            HStack(spacing: 12) {
                // Group icon preview
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: "5E8CFF").opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(hex: "5E8CFF").opacity(0.3), lineWidth: 0.5)
                        }
                        .frame(width: 44, height: 44)
                    Text(groupName.isEmpty
                         ? "G"
                         : String(groupName.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: "5E8CFF"))
                }

                TextField("", text: $groupName,
                          prompt: Text("Название группы").foregroundStyle(Color.textTertiary))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .submitLabel(.done)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassBackground(cornerRadius: 16, opacity: 0.38)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var selectedChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Участники (\(selectedUsers.count))")
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selectedUsers) { user in
                        memberChip(user)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 8)
        }
    }

    private func memberChip(_ user: User) -> some View {
        HStack(spacing: 6) {
            AvatarView(
                url: user.avatarURL,
                initials: user.initials,
                size: 24,
                avatarColorOverride: avatarColor(for: user.id)
            )
            Text(user.nickname)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Button {
                withAnimation(.spring(response: 0.25)) {
                    selectedUsers.removeAll { $0.id == user.id }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassBackground(cornerRadius: 20, opacity: 0.45)
        .transition(.scale.combined(with: .opacity))
    }

    private var searchSection: some View {
        GlassSearchBar(text: $searchText, placeholder: "Поиск пользователей")
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .onChange(of: searchText) { _, q in
                searchTask?.cancel()
                guard q.count >= 2 else { foundUsers = []; return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    isSearching = true
                    let results = try? await APIClient.shared.searchUsers(query: q)
                    await MainActor.run {
                        foundUsers = (results ?? []).filter { u in
                            u.id != appState.currentUser?.id
                        }
                        isSearching = false
                    }
                }
            }
    }

    private var userResults: some View {
        LazyVStack(spacing: 0) {
            ForEach(foundUsers) { user in
                let isSelected = selectedUsers.contains { $0.id == user.id }
                UserSearchRow(user: user, isSelected: isSelected)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25)) {
                            if isSelected {
                                selectedUsers.removeAll { $0.id == user.id }
                            } else {
                                selectedUsers.append(user)
                            }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                Divider()
                    .background(Color.glassBorder)
                    .padding(.leading, 72)
            }

            if foundUsers.isEmpty && searchText.count >= 2 && !isSearching {
                VStack(spacing: 10) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(Color.textTertiary)
                    Text("Пользователи не найдены")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textTertiary)
                }
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
            } else if searchText.count < 2 {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(Color.textTertiary)
                    Text("Введите имя для поиска участников")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
            }
        }
    }

    private var createButton: some View {
        Button {
            guard canCreate else { return }
            createGroup()
        } label: {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().tint(.black).scaleEffect(0.85)
                } else {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(isCreating ? "Создание..." : "Создать группу")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(canCreate ? .black : Color.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                canCreate ? Color.white.opacity(0.92) : Color.glassSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.glassBorder, lineWidth: 0.5)
            }
            .shadow(color: .white.opacity(canCreate ? 0.15 : 0), radius: 14)
        }
        .disabled(!canCreate || isCreating)
        .animation(.easeInOut(duration: 0.18), value: canCreate)
    }

    // MARK: Create Action

    private func createGroup() {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        let ids = selectedUsers.map { $0.id }
        isCreating = true
        errorMsg = nil
        Task {
            do {
                let chat = try await APIClient.shared.createGroupChat(name: name, memberIds: ids)
                await MainActor.run { onCreated(chat) }
            } catch {
                errorMsg = error.localizedDescription
            }
            isCreating = false
        }
    }
}
