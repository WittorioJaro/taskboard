import AppKit
import SwiftUI

enum TaskAttachmentStore {
    static func pasteImage() -> TaskAttachment? {
        guard let image = NSImage(pasteboard: .general) else { return nil }
        return save(image: image)
    }

    static var hasImageOnPasteboard: Bool {
        NSImage(pasteboard: .general) != nil
    }

    static func delete(_ attachment: TaskAttachment) {
        try? FileManager.default.removeItem(atPath: attachment.path)
    }

    private static func save(image: NSImage) -> TaskAttachment? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let id = UUID()
        let fileName = "pasted-image-\(id.uuidString.lowercased()).png"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("taskboard", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        guard let directory else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            return TaskAttachment(id: id, fileName: fileName, path: url.path)
        } catch {
            NSLog("taskboard attachment error: \(error.localizedDescription)")
            return nil
        }
    }
}

struct AttachmentDraftStrip: View {
    let attachments: [TaskAttachment]
    var onRemove: ((TaskAttachment) -> Void)?

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentThumbnail(attachment: attachment, onRemove: onRemove)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: TaskAttachment
    var onRemove: ((TaskAttachment) -> Void)?
    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { isExpanded = true } label: {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Open \(attachment.fileName)")

            if let onRemove {
                Button { onRemove(attachment) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.primary)
                        .frame(width: 16, height: 16)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .sheet(isPresented: $isExpanded) {
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded = false }
                image
                    .resizable()
                    .scaledToFit()
                    .padding(28)
                    .onTapGesture { }
                Button { isExpanded = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(14)
            }
            .frame(minWidth: 640, minHeight: 480)
        }
    }

    private var image: Image {
        if let nsImage = NSImage(contentsOfFile: attachment.path) {
            Image(nsImage: nsImage)
        } else {
            Image(systemName: "photo.badge.exclamationmark")
        }
    }
}

struct PasteAttachmentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Paste image from clipboard")
    }
}
