---
name: executive-deck-builder
description: Builds a high-fidelity, executive-ready PowerPoint (.pptx) file from permission-trimmed Microsoft Fabric results. Use whenever the user asks for a deck, presentation, slides, report, or readout.
---

# Executive deck builder

Build a real `.pptx` file with code interpreter and `python-pptx`, then return it for
download. Never stop at a slide plan and never ask the user to build the file.

## 1. Gather Fabric evidence first

Use the configured Fabric OBO tool for at least three complementary requests before
writing presentation code:

1. A categorical breakdown, such as shortages by supplier or region.
2. A time trend, such as open shortages by month.
3. A composition or secondary dimension, such as impact by part family.

Use only values returned under the signed-in user's Fabric permissions. Never invent,
estimate, or extrapolate. If a request returns no rows, state that limitation instead of
guessing. Pass compact structured data, source table names, units, filters, and as-of dates
to the code-interpreter prompt.

## 2. Canvas and layout

- Use 16:9 widescreen: `prs.slide_width = Inches(13.333)` and
  `prs.slide_height = Inches(7.5)`.
- Use the blank layout `prs.slide_layouts[6]` and place every element explicitly.
- Keep content inside a 0.6 inch margin. Reserve 0.75 inch for the header and 0.4 inch
  for the footer.
- Never overlap shapes. Cap titles at 90 characters and bullets at 120 characters.
- Use body text of at least 14 pt and slide titles of 28-32 pt bold.

## 3. Header, footer, and branding

Every slide except the title slide carries:

- A Microsoft mark at top left: four 0.12 inch squares in a 2x2 grid with a 0.02 inch
  gap. Use `#F25022`, `#7FBA00`, `#00A4EF`, and `#FFB900`.
- `Microsoft` to the right of the mark in Segoe UI, 12 pt, `#737373`.
- A 1 pt `#E5E5E5` rule beneath the header across the content width.
- The deck title at footer left and slide number at footer right in Segoe UI, 9 pt,
  `#737373`.

If official customer artwork is supplied, use it instead of a drawn approximation.

## 4. Visual fidelity

Create native PowerPoint charts with `CategoryChartData` and `add_chart`; do not insert
chart screenshots.

| Purpose | Chart type |
| --- | --- |
| Trend over time | `XL_CHART_TYPE.LINE_MARKERS` |
| Category comparison | `XL_CHART_TYPE.COLUMN_CLUSTERED` |
| Share of total | `XL_CHART_TYPE.DOUGHNUT` |
| Measures with different scales | Clustered columns plus a secondary-axis line |

Every chart needs a title, axis titles with units, data labels, an appropriate number
format, and a legend only for multiple series. Use `#,##0` for counts, `$#,##0,,"M"`
for millions of dollars, and `0.0%` for rates. Apply colors in this order:
`#0078D4`, `#50E6FF`, `#243A5E`, `#FFB900`, `#D83B01`, `#107C10`.

Use a `#243A5E` table header with white bold text, 10-11 pt body text, right-aligned
numeric values, and units in column headings. Limit tables to 12 rows and 6 columns;
aggregate remaining rows into `Other` only when the source results support it.

Use rounded-rectangle KPI tiles with a 28-32 pt bold `#243A5E` value and an 11 pt
`#737373` label that includes unit and period. Build diagrams with real PowerPoint shapes
and connectors.

## 5. Deck structure

Always include:

1. Title: question, date, and source `Microsoft Fabric (delegated user permissions)`.
2. Executive summary: three to five bullets, each containing a returned number.
3. Evidence: at least one native chart or table supporting the summary.
4. Findings and recommendations: each tied to a returned number.

Add KPI, trend, comparison, composition, detail-table, process, or segment slides only
when the evidence warrants them. A short readout can use four slides; a full executive
review commonly uses nine to twelve, without padding. Make slide titles assertions that
carry a number, not generic labels. Add speaker notes explaining derivation, filters, and
source tables for every slide.

## 6. Verify before returning

After saving, reopen the file and verify that:

- it is a ZIP-based Office file containing `ppt/presentation.xml`;
- all four core slides are present;
- planned chart slides contain chart objects and planned table slides contain tables;
- no text frame overflows its shape; and
- no number appears unless it came from a recorded Fabric result.

Return exactly one `.pptx` file with a concise summary of its contents.