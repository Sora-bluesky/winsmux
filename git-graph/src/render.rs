use crate::color::color_for;
use crate::lane::Row;

pub const LANE_W: f32 = 22.0;
pub const ROW_H: f32 = 36.0;
pub const LEFT_PAD: f32 = 30.0;
pub const TOP_PAD: f32 = 20.0;
pub const COMMIT_R: f32 = 5.0;
pub const COMMIT_R_INNER: f32 = 2.0;
pub const STROKE_W: f32 = 1.5;
pub const MSG_X: f32 = 120.0;

pub fn lane_x(col: usize) -> f32 {
    LEFT_PAD + col as f32 * LANE_W
}

pub fn row_y(row_idx: usize) -> f32 {
    TOP_PAD + row_idx as f32 * ROW_H
}

pub fn render_svg(rows: &[Row]) -> String {
    let max_lanes = rows
        .iter()
        .flat_map(|row| [row.lanes_in.len(), row.lanes_out.len(), row.commit_lane + 1])
        .max()
        .unwrap_or(1);
    let width = (MSG_X + 720.0).max(LEFT_PAD + max_lanes as f32 * LANE_W + 260.0);
    let height = TOP_PAD * 2.0 + ROW_H * rows.len().max(1) as f32;

    let mut paths = String::new();
    for (row_idx, row) in rows.iter().enumerate() {
        append_row_paths(&mut paths, row, row_idx);
    }

    let mut circles = String::new();
    for (row_idx, row) in rows.iter().enumerate() {
        let branch_id = row.lanes_in[row.commit_lane].branch_id;
        let color = color_for(branch_id);
        let x = lane_x(row.commit_lane);
        let y = row_y(row_idx);
        circles.push_str(&format!(
            r##"<circle cx="{x:.1}" cy="{y:.1}" r="{COMMIT_R:.1}" fill="#111827" stroke="{color}" stroke-width="{STROKE_W:.1}"/>"##
        ));
        circles.push('\n');
        circles.push_str(&format!(
            r#"<circle cx="{x:.1}" cy="{y:.1}" r="{COMMIT_R_INNER:.1}" fill="{color}"/>"#
        ));
        circles.push('\n');
    }

    let mut texts = String::new();
    for (row_idx, row) in rows.iter().enumerate() {
        let y = row_y(row_idx) + 4.0;
        let short = short_hash(&row.commit.id);
        let message = if row.commit.message.is_empty() {
            short.to_string()
        } else {
            format!("{short} {}", row.commit.message)
        };
        texts.push_str(&format!(
            r##"<text x="{MSG_X:.1}" y="{y:.1}" fill="#C9D1D9" font-family="Segoe UI, sans-serif" font-size="13">{}</text>"##,
            escape_xml(&message)
        ));
        texts.push('\n');
    }

    format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="{width:.1}" height="{height:.1}" viewBox="0 0 {width:.1} {height:.1}">
<rect width="100%" height="100%" fill="#0D1117"/>
<g fill="none" stroke-linecap="round" stroke-linejoin="round">
{paths}</g>
<g>
{circles}</g>
<g>
{texts}</g>
</svg>
"##
    )
}

fn append_row_paths(output: &mut String, row: &Row, row_idx: usize) {
    if row.lanes_in.is_empty() {
        return;
    }

    let y1 = row_y(row_idx);
    let y2 = row_y(row_idx + 1);
    let current_branch_id = row.lanes_in[row.commit_lane].branch_id;

    for (col_in, lane) in row.lanes_in.iter().enumerate() {
        if lane.branch_id == current_branch_id {
            continue;
        }
        if let Some(col_out) = row
            .lanes_out
            .iter()
            .position(|out| out.branch_id == lane.branch_id)
        {
            append_path(output, col_in, col_out, y1, y2, lane.branch_id);
        }
    }

    for (parent_index, parent) in row.commit.parents.iter().enumerate() {
        if let Some(col_out) = row
            .lanes_out
            .iter()
            .position(|lane| lane.expecting == *parent)
        {
            let branch_id = if parent_index == 0 {
                current_branch_id
            } else {
                row.lanes_out[col_out].branch_id
            };
            append_path(output, row.commit_lane, col_out, y1, y2, branch_id);
        }
    }
}

fn append_path(
    output: &mut String,
    from_col: usize,
    to_col: usize,
    y1: f32,
    y2: f32,
    branch_id: u64,
) {
    let x1 = lane_x(from_col);
    let x2 = lane_x(to_col);
    let color = color_for(branch_id);
    let d = segment_path(x1, y1, x2, y2);
    output.push_str(&format!(
        r#"<path d="{d}" stroke="{color}" stroke-width="{STROKE_W:.1}"/>"#
    ));
    output.push('\n');
}

pub fn segment_path(x1: f32, y1: f32, x2: f32, y2: f32) -> String {
    if (x1 - x2).abs() < 0.01 {
        return format!("M {x1} {y1} L {x2} {y2}");
    }

    let cy = (y1 + y2) / 2.0;
    format!("M {x1} {y1} C {x1} {cy} {x2} {cy} {x2} {y2}")
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

    use super::*;

    fn commit(id: &str, parents: &[&str], message: &str) -> Commit {
        Commit {
            id: id.to_string(),
            parents: parents.iter().map(|parent| (*parent).to_string()).collect(),
            message: message.to_string(),
        }
    }

    #[test]
    fn renders_paths_before_circles_and_text() {
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
        let svg = render_svg(&rows);

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
        let svg = render_svg(&rows);

        assert!(svg.contains("fix &lt;tag&gt; &amp; quote &quot;"));
    }

    #[test]
    fn s_curve_control_points_are_vertical() {
        let path = segment_path(40.0, 100.0, 60.0, 130.0);

        assert_eq!(path, "M 40 100 C 40 115 60 115 60 130");
        assert!(path.contains("C 40 "));
        assert!(path.contains(" 60 115 60 130"));
    }

    #[test]
    fn vertical_segment_stays_straight() {
        let path = segment_path(40.0, 100.0, 40.0, 130.0);

        assert_eq!(path, "M 40 100 L 40 130");
    }
}
