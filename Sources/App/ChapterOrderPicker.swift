import SwiftUI

struct ChapterOrderPicker: View {
    @Binding var descending: Bool
    var body: some View {
        Picker("目录顺序", selection: $descending) {
            Text("正序").tag(false)
            Text("倒序").tag(true)
        }.pickerStyle(.segmented).accessibilityIdentifier("catalog.order")
    }
}
