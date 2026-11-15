import SwiftUI
import WidgetKit

@main
struct PinDropWidgetBundle: WidgetBundle {
    var body: some Widget {
        PinDropWidget()
    }
}

/// Home Screen (small, medium) and Lock Screen (circular) widget, localized via the shared
/// `Localizable.xcstrings` catalog.
struct PinDropWidget: Widget {
    let kind: String = AppGroup.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PinDropTimelineProvider()) { entry in
            PinDropWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widget.displayName")
        .description("widget.description")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
        .contentMarginsDisabled()
    }
}
