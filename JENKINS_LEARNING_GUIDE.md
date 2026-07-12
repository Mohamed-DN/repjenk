# JENKINS_LEARNING_GUIDE.md

## 1. Introduction to Jenkins for Oracle DBAs
Jenkins is a continuous integration and continuous delivery (CI/CD) server. For Oracle DBAs, it acts as a robust replacement for traditional cron jobs or shell scripts used to automate Data Pump operations. By using Jenkins, DBAs gain visibility, auditability, central parameter management, and seamless pipeline orchestrations.

## 2. Pipelines and Stages
**Concept**: In Jenkins, a Pipeline is an automated process for executing tasks. A Pipeline is broken down logically into `stage`s. Each stage performs a specific part of the work, making it easy to monitor progress, catch errors, and organize complex workflows.
**Mapping**: In our pipeline (`Jenkinsfile`), execution is broken down into explicit logical stages, e.g., `stage('Export')` (Line 639) and `stage('Import')` (Line 767).

## 3. Nodes and Agents
**Concept**: An Agent (or Node) is a machine or container that connects to the Jenkins master to execute tasks. By defining agents, workloads are directed to specific servers equipped with the right tools.
**Mapping**: In our codebase, the global agent is defined as `agent { label 'oracle-dba' }` (Line 17), ensuring that execution only runs on correctly configured Oracle client nodes.

## 4. Credentials Management
**Concept**: Jenkins provides a secure Credentials Store to prevent secret leakage in scripts or logs.
**Mapping**: Credentials are fetched using the native `credentials()` step in the environment block (e.g., `credentials('eni-src-db-credentials')` at Line 51) and securely consumed using the `withCredentials` block during pipeline steps, fully protecting passwords.

## 5. Shared Libraries
**Concept**: Shared Libraries allow code reuse across multiple Jenkins pipelines, keeping `Jenkinsfile`s declarative and highly readable by externalizing complex scripts (like shell scripts or PL/SQL).
**Mapping**: In our codebase, the library is imported via `@Library('eni-oracle-shared-library')` (Line 14). Functions like `autonomousExport` are housed securely in `vars/oracleDataPump.groovy`.

## Recommended Citations:
1. [Jenkins Official Docs: Pipeline Syntax](https://www.jenkins.io/doc/book/pipeline/syntax/) (For Declarative Pipeline constructs)
2. [Jenkins Official Docs: Using Credentials](https://www.jenkins.io/doc/book/using/using-credentials/) (For Secret Management)
3. [Oracle Architecture Center: Automate Database Deployments](https://docs.oracle.com/en/solutions/automate-db-deployments/) (For CI/CD database best practices)
