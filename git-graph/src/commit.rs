use std::io::{self, Read};
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Commit {
    pub id: String,
    pub parents: Vec<String>,
    pub message: String,
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
        let parents = commit.parent_ids().map(|parent| parent.to_string()).collect();
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
        assert_eq!(commits[0].parents, vec!["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]);
        assert_eq!(commits[0].message, "aaaaaaaaaaaa");
        assert_eq!(commits[1].parents, Vec::<String>::new());
    }
}
