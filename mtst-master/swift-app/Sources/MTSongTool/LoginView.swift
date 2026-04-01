import SwiftUI

struct LoginView: View {
    @ObservedObject var settings: UserSettings
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var continueHovered: Bool = false

    private var canContinue: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Traffic-light spacer
                Color.clear.frame(height: 28)

                Spacer()

                // Logo
                VStack(spacing: 4) {
                    Text("MTST")
                        .font(.horizon(size: 48))
                        .foregroundColor(.accent)

                    Text("MultiTracks Song Tool")
                        .font(.lato(size: 11, weight: .regular))
                        .foregroundColor(.fgDim)
                        .kerning(0.3)
                }
                .padding(.bottom, 40)

                // Name fields
                VStack(spacing: 14) {
                    nameField(placeholder: "First Name", text: $firstName)
                    nameField(placeholder: "Last Name", text: $lastName)
                }
                .frame(width: 260)
                .padding(.bottom, 24)

                // Continue button
                Button {
                    settings.firstName = firstName.trimmingCharacters(in: .whitespaces)
                    settings.lastName = lastName.trimmingCharacters(in: .whitespaces)
                } label: {
                    Text("Continue")
                        .font(.lato(size: 14, weight: .semibold))
                        .foregroundColor(canContinue ? .white : Color.submitOffFg)
                        .frame(width: 260)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(canContinue ? Color.accent : Color.submitOff)
                        )
                }
                .buttonStyle(.plain)
                .brightness(continueHovered && canContinue ? 0.07 : 0)
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.12)) { continueHovered = h }
                    if h && canContinue { NSCursor.pointingHand.set() } else if !h { NSCursor.arrow.set() }
                }
                .disabled(!canContinue)
                .animation(.easeOut(duration: 0.2), value: canContinue)

                Spacer()
            }
        }
        .frame(minWidth: 680, minHeight: 580)
    }

    private func nameField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.lato(size: 14))
            .foregroundColor(.fgBright)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.inputBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.border, lineWidth: 1)
                    )
            )
            .onSubmit {
                if canContinue {
                    settings.firstName = firstName.trimmingCharacters(in: .whitespaces)
                    settings.lastName = lastName.trimmingCharacters(in: .whitespaces)
                }
            }
    }
}
