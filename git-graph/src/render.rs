use crate::color::color_for;
use crate::commit::CommitKind;
use crate::lane::Row;
use crate::layout::{GraphLayout, LaneSpan, MergeMarker};

pub const LANE_W: f32 = 8.0;
pub const ROW_H: f32 = 22.0;
pub const COMMIT_R: f32 = 2.5;
pub const HEAD_R: f32 = 3.5;
pub const MERGE_R: f32 = 2.0;
pub const STROKE_W: f32 = 1.0;
pub const LEFT_PAD: f32 = 8.0;
pub const TOP_PAD: f32 = 11.0;
pub const CURVE_ZONE: f32 = 5.0;

const BACKGROUND: &str = "#0D1117";
const TEXT: &str = "#C9D1D9";

pub fn lane_x(col: usize) -> f32 {
    LEFT_PAD + col as f32 * LANE_W + 0.5
}

pub fn row_y(row_idx: usize) -> f32 {
    TOP_PAD + row_idx as f32 * ROW_H + 0.5
}

pub fn message_x(max_lanes: usize) -> f32 {
    LEFT_PAD + max_lanes.max(1) as f32 * LANE_W + 16.0
}

pub fn render_svg(layout: &GraphLayout, head_id: Option<&str>) -> String {
    let max_lanes = max_lanes(layout);
    let message_x = message_x(max_lanes);
    let width = message_x + 720.0;
    let height = TOP_PAD * 2.0 + ROW_H * (layout.rows.len().max(1) + 1) as f32;

    let mut spans = String::new();
    for span in &layout.lane_spans {
        spans.push_str(&render_lane_span(span));
        spans.push('\n');
    }

    let mut bridges = String::new();
    for (row_idx, row) in layout.rows.iter().enumerate() {
        render_lane_bridges(&mut bridges, row, row_idx);
    }

    let mut circles = String::new();
    for (row_idx, row) in layout.rows.iter().enumerate() {
        if let Some(circle) = render_row_commit_circle(row, row_idx, head_id) {
            circles.push_str(&circle);
            circles.push('\n');
        }
    }

    let mut markers = String::new();
    for marker in &layout.merge_markers {
        markers.push_str(&render_merge_marker(marker));
        markers.push('\n');
    }

    let mut texts = String::new();
    for (row_idx, row) in layout.rows.iter().enumerate() {
        let y = row_y(row_idx) + 4.0;
        let short = short_hash(&row.commit.id);
        let message = if row.commit.message.is_empty() {
            short.to_string()
        } else {
            format!("{short} {}", row.commit.message)
        };
        texts.push_str(&format!(
            r#"<text x="{message_x:.1}" y="{y:.1}" fill="{TEXT}" font-family="Segoe UI, sans-serif" font-size="13">{}</text>"#,
            escape_xml(&message)
        ));
        texts.push('\n');
    }

    format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="{width:.1}" height="{height:.1}" viewBox="0 0 {width:.1} {height:.1}">
<rect width="100%" height="100%" fill="{BACKGROUND}"/>
<g fill="none" stroke-linecap="round" stroke-linejoin="round">
{spans}</g>
<g fill="none" stroke-linecap="round" stroke-linejoin="round">
{bridges}</g>
<g>
{circles}</g>
<g>
{markers}</g>
<g>
{texts}</g>
</svg>
"##
    )
}

fn max_lanes(layout: &GraphLayout) -> usize {
    layout
        .rows
        .iter()
        .flat_map(|row| [row.lanes_in.len(), row.lanes_out.len(), row.commit_lane + 1])
        .chain(layout.lane_spans.iter().map(|span| span.col + 1))
        .chain(
            layout
                .merge_markers
                .iter()
                .map(|marker| marker.from_col + 1),
        )
        .chain(layout.merge_markers.iter().map(|marker| marker.to_col + 1))
        .max()
        .unwrap_or(1)
}

fn render_lane_span(span: &LaneSpan) -> String {
    let x = lane_x(span.col);
    let y_start = row_y(span.start_row);
    let y_end = row_y(span.end_row);
    let color = color_for(span.branch_id);

    format!(
        r#"<path d="M {x:.1} {y_start:.1} L {x:.1} {y_end:.1}" stroke="{color}" stroke-width="{STROKE_W}" fill="none"/>"#
    )
}

fn render_lane_bridges(output: &mut String, row: &Row, row_idx: usize) {
    if row.lanes_in.is_empty() || row.commit_lane >= row.lanes_in.len() {
        return;
    }

    let current_branch_id = row.lanes_in[row.commit_lane].branch_id;
    let y_top = row_y(row_idx);
    let y_bottom = row_y(row_idx + 1);

    for (col_in, lane) in row.lanes_in.iter().enumerate() {
        if lane.branch_id == current_branch_id {
            continue;
        }
        let Some(col_out) = row
            .lanes_out
            .iter()
            .position(|out| out.branch_id == lane.branch_id)
        else {
            continue;
        };
        if col_in != col_out {
            append_bridge(output, col_in, col_out, y_top, y_bottom, lane.branch_id);
        }
    }

    for (parent_index, parent) in row.commit.parents.iter().enumerate() {
        let Some(col_out) = row
            .lanes_out
            .iter()
            .position(|lane| lane.expecting == *parent)
        else {
            continue;
        };

        let branch_id = if parent_index == 0 {
            current_branch_id
        } else {
            row.lanes_out[col_out].branch_id
        };
        if row.commit_lane != col_out {
            append_bridge(output, row.commit_lane, col_out, y_top, y_bottom, branch_id);
        }
    }
}

fn append_bridge(
    output: &mut String,
    from_col: usize,
    to_col: usize,
    y_top: f32,
    y_bottom: f32,
    branch_id: u64,
) {
    let x1 = lane_x(from_col);
    let x2 = lane_x(to_col);
    let color = color_for(branch_id);
    let d = lane_shift_path(x1, x2, y_top, y_bottom);
    output.push_str(&format!(
        r#"<path d="{d}" stroke="{color}" stroke-width="{STROKE_W}" fill="none"/>"#
    ));
    output.push('\n');
}

pub fn lane_shift_path(x1: f32, x2: f32, y_top: f32, y_bottom: f32) -> String {
    if (x1 - x2).abs() < 0.01 {
        return format!("M {x1:.1} {y_top:.1} L {x2:.1} {y_bottom:.1}");
    }

    let middle = (y_top + y_bottom) / 2.0;
    let curve_top = (middle - CURVE_ZONE).max(y_top);
    let curve_bottom = (middle + CURVE_ZONE).min(y_bottom);
    let cy_a = curve_top + (curve_bottom - curve_top) * 0.4;
    let cy_b = curve_top + (curve_bottom - curve_top) * 0.6;

    format!(
        "M {x1:.1} {y_top:.1} L {x1:.1} {curve_top:.1} C {x1:.1} {cy_a:.1} {x2:.1} {cy_b:.1} {x2:.1} {curve_bottom:.1} L {x2:.1} {y_bottom:.1}"
    )
}

fn render_row_commit_circle(row: &Row, row_idx: usize, head_id: Option<&str>) -> Option<String> {
    let branch_id = row.lanes_in.get(row.commit_lane)?.branch_id;
    let color = color_for(branch_id);
    let cx = lane_x(row.commit_lane);
    let cy = row_y(row_idx);
    let kind = row.commit.kind(head_id == Some(row.commit.id.as_str()));

    Some(render_commit_circle(kind, cx, cy, color))
}

fn render_commit_circle(kind: CommitKind, cx: f32, cy: f32, color: &str) -> String {
    match kind {
        CommitKind::Head => format!(
            r##"<circle cx="{cx:.1}" cy="{cy:.1}" r="{HEAD_R:.1}" fill="{BACKGROUND}" stroke="{color}" stroke-width="1.2"/>"##
        ),
        CommitKind::Normal => format!(
            r##"<circle cx="{cx:.1}" cy="{cy:.1}" r="{COMMIT_R:.1}" fill="{BACKGROUND}" stroke="{color}" stroke-width="{STROKE_W}"/>"##
        ),
        CommitKind::Merge => {
            format!(r#"<circle cx="{cx:.1}" cy="{cy:.1}" r="{MERGE_R:.1}" fill="{color}"/>"#)
        }
    }
}

fn render_merge_marker(marker: &MergeMarker) -> String {
    let cx = lane_x(marker.from_col);
    let cy = row_y(marker.row);
    let color = color_for(marker.color_idx);

    format!(
        r##"<circle cx="{cx:.1}" cy="{cy:.1}" r="{MERGE_R:.1}" fill="{BACKGROUND}" stroke="{color}" stroke-width="{STROKE_W}"/>"##
    )
}

fn short_hash(id: &str) -> &str {
    id.get(..7).unwrap_or(id)
}

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use crate::commit::Commit;
    use crate::lane::assign_lanes;
    use crate::layout::build_layout;

    use super::*;

    fn commit(id: &str, parents: &[&str], message: &str) -> Commit {
        Commit {
            id: id.to_string(),
            parents: parents.iter().map(|parent| (*parent).to_string()).collect(),
            message: message.to_string(),
        }
    }

    #[test]
    fn renders_layers_in_order() {
        let rows = assign_lanes(&[
            commit(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                &[
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "cccccccccccccccccccccccccccccccccccccccc",
                ],
                "merge",
            ),
            commit(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                &["dddddddddddddddddddddddddddddddddddddddd"],
                "main",
            ),
            commit(
                "cccccccccccccccccccccccccccccccccccccccc",
                &["dddddddddddddddddddddddddddddddddddddddd"],
                "feature",
            ),
            commit("dddddddddddddddddddddddddddddddddddddddd", &[], "root"),
        ]);
        let layout = build_layout(rows);
        let svg = render_svg(&layout, Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

        let path_index = svg.find("<path").expect("path should render");
        let circle_index = svg.find("<circle").expect("circle should render");
        let text_index = svg.find("<text").expect("text should render");
        assert!(path_index < circle_index);
        assert!(circle_index < text_index);
        assert!(svg.contains(" C "));
    }

    #[test]
    fn escapes_xml_text() {
        let rows = assign_lanes(&[commit(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            &[],
            "fix <tag> & quote \"",
        )]);
        let layout = build_layout(rows);
        let svg = render_svg(&layout, None);

        assert!(svg.contains("fix &lt;tag&gt; &amp; quote &quot;"));
    }

    #[test]
    fn lane_shift_path_has_vertical_endcaps() {
        let path = lane_shift_path(40.0, 60.0, 100.0, 130.0);

        assert_eq!(
            path,
            "M 40.0 100.0 L 40.0 110.0 C 40.0 114.0 60.0 116.0 60.0 120.0 L 60.0 130.0"
        );
        assert!(path.contains("C 40.0 "));
        assert!(path.contains(" 60.0 120.0 L 60.0 130.0"));
    }

    #[test]
    fn straight_lane_shift_uses_only_line_command() {
        let path = lane_shift_path(40.0, 40.0, 100.0, 130.0);

        assert_eq!(path, "M 40.0 100.0 L 40.0 130.0");
        assert!(!path.contains(" C "));
    }

    #[test]
    fn head_circle_is_larger_than_normal() {
        let rows = assign_lanes(&[
            commit(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                &["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
                "head",
            ),
            commit("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &[], "base"),
        ]);
        let layout = build_layout(rows);
        let svg = render_svg(&layout, Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

        assert!(svg.contains(r#"r="3.5""#));
        assert!(svg.contains(r#"r="2.5""#));
    }

    #[test]
    fn compact_graph_width_stays_under_eighty_pixels_for_six_lanes() {
        let right_edge = lane_x(5) + HEAD_R;

        assert!(right_edge <= 80.0);
        assert_eq!(message_x(6), 72.0);
    }
}
