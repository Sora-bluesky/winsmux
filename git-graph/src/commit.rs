use std::io::{self, Read};
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Commit {
    pub id: String,
    pub parents: Vec<String>,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitKind {
    Head,
    Merge,
    Normal,
}

impl Commit {
    pub fn kind(&self, is_head: bool) -> CommitKind {
        if is_head {
            CommitKind::Head
        } else if self.parents.len() >= 2 {
            CommitKind::Merge
        } else {
            CommitKind::Normal
        }
    }
}

pub fn parse_stdin_log(input: &str) -> Vec<Commit> {
    input
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return None;
            }
            let mut parts = trimmed.split_whitespace();
            let id = parts.next()?.to_string();
            let parents = parts.map(String::from).collect();
            Some(Commit {
                message: id.chars().take(12).collect(),
                id,
                parents,
            })
        })
        .collect()
}

pub fn read_stdin_log() -> io::Result<Vec<Commit>> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    Ok(parse_stdin_log(&input))
}

pub fn read_repo_commits(repo_path: &Path, max: usize) -> Result<Vec<Commit>, git2::Error> {
    let repo = git2::Repository::discover(repo_path)?;
    let mut revwalk = repo.revwalk()?;
    revwalk.push_head()?;
    revwalk.set_sorting(git2::Sort::TOPOLOGICAL | git2::Sort::TIME)?;

    let mut commits = Vec::new();
    for oid_result in revwalk.take(max) {
        let oid = oid_result?;
        let commit = repo.find_commit(oid)?;
        let parents = commit
            .parent_ids()
            .map(|parent| parent.to_string())
            .collect();
        commits.push(Commit {
            id: oid.to_string(),
            parents,
            message: commit.summary().unwrap_or("").to_string(),
        });
    }

    Ok(commits)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_stdin_log_lines() {
        let commits = parse_stdin_log("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n");

        assert_eq!(commits.len(), 2);
        assert_eq!(commits[0].id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert_eq!(
            commits[0].parents,
            vec!["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]
        );
        assert_eq!(commits[0].message, "aaaaaaaaaaaa");
        assert_eq!(commits[1].parents, Vec::<String>::new());
    }

    #[test]
    fn classifies_commit_kind() {
        let normal = Commit {
            id: "A".to_string(),
            parents: vec!["B".to_string()],
            message: "A".to_string(),
        };
        let merge = Commit {
            id: "M".to_string(),
            parents: vec!["A".to_string(), "B".to_string()],
            message: "M".to_string(),
        };

        assert_eq!(normal.kind(false), CommitKind::Normal);
        assert_eq!(merge.kind(false), CommitKind::Merge);
        assert_eq!(merge.kind(true), CommitKind::Head);
    }
}
