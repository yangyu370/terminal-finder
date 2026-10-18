package finderui

// FinderMetrics records points calibrated against the supplied lossless Finder
// reference at 2 device pixels per point. Every value here drives live components.
// SidebarRadius is fitted, not independently measured.
// Color, glyph and material fidelity are audited separately from these dimensions.
type FinderMetrics struct {
	SidebarWidth, SidebarRadius                                float32
	ToolbarHeight, HeaderHeight                                float32
	RowHeight, RowInset, RowTopInset, RowRadius                float32
	CapsuleHeight, ButtonWidth, ButtonHeight, ToolbarGlyph     float32
	BodyFont, MetadataFont, HeaderFont, SidebarFont, TitleFont float32
	DateWidth, SizeWidth, KindWidth                            float32
}

var Finder26 = FinderMetrics{
	SidebarWidth: 176, SidebarRadius: 22,
	ToolbarHeight: 52, HeaderHeight: 28,
	RowHeight: 20, RowInset: 10, RowTopInset: 5, RowRadius: 10,
	CapsuleHeight: 36, ButtonWidth: 36, ButtonHeight: 34, ToolbarGlyph: 22,
	BodyFont: 13, MetadataFont: 13, HeaderFont: 11, SidebarFont: 13, TitleFont: 15,
	DateWidth: 181, SizeWidth: 97, KindWidth: 132,
}
