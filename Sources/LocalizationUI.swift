import AppKit

extension Localizer {
    static func refresh(_ window: NSWindow) {
        window.title = displayed(window.title)
        if let view = window.contentView { refresh(view) }
    }
    static func refresh(_ view: NSView) {
        if let field = view as? NSTextField {
            if !field.isEditable { field.stringValue = displayed(field.stringValue) }
            if let placeholder = field.placeholderString { field.placeholderString = displayed(placeholder) }
        }
        if let button = view as? NSButton { button.title = displayed(button.title) }
        if let segmented = view as? NSSegmentedControl {
            for index in 0..<segmented.segmentCount {
                if let title = segmented.label(forSegment: index) { segmented.setLabel(displayed(title), forSegment: index) }
            }
        }
        if let table = view as? NSTableView {
            for column in table.tableColumns { column.title = displayed(column.title) }
            // Row cells contain filenames or CSV data. Do not walk into them.
            if let tooltip = table.toolTip { table.toolTip = displayed(tooltip) }
            return
        }
        if let tooltip = view.toolTip { view.toolTip = displayed(tooltip) }
        if let label = view.accessibilityLabel() { view.setAccessibilityLabel(displayed(label)) }
        if let menu = view.menu { refresh(menu) }
        if view is NSTextView { return }
        // Editor and terminal contents belong to the user and are never translated.
        for child in view.subviews { refresh(child) }
    }
    static func refresh(_ menu: NSMenu) {
        menu.title = displayed(menu.title)
        for item in menu.items {
            item.title = displayed(item.title)
            if let submenu = item.submenu { refresh(submenu) }
        }
    }
}
