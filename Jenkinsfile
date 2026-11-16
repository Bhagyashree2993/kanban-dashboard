// =============================================================================
// CI/CD: GitHub -> Jenkins -> docker build -> scan -> Docker Hub -> EC2 (blue-green) -> validate
//
// Jenkins credentials required (Manage Jenkins > Credentials), never in code:
//   dockerhub-creds : "Username with password"  (Docker Hub user + access token)
//   ec2-ssh-key     : "SSH Username with private key" (only when DEPLOY_MODE=ssh)
// =============================================================================

// Run a shell command on the deploy target: locally (Jenkins lives on the same EC2)
// or over SSH (Jenkins on a different machine).
def onTarget(String cmd) {
    if (params.DEPLOY_MODE == 'ssh') {
        sshagent(credentials: ['ec2-ssh-key']) {
            sh """
                scp -o StrictHostKeyChecking=accept-new deploy/deploy.sh ${params.EC2_USER}@${params.EC2_HOST}:/tmp/kanban-deploy.sh
                ssh -o StrictHostKeyChecking=accept-new ${params.EC2_USER}@${params.EC2_HOST} 'bash /tmp/kanban-deploy.sh ${cmd}'
            """
        }
    } else {
        sh "bash deploy/deploy.sh ${cmd}"
    }
}

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 30, unit: 'MINUTES')
    }

    triggers {
        githubPush()   // fired by the GitHub webhook -> http://<EC2-IP>:8080/github-webhook/
    }

    parameters {
        string(name: 'DOCKERHUB_REPO', defaultValue: 'guvibhagyashreekhandare/kanban-dashboard', description: 'Docker Hub repository (user/name)')
        choice(name: 'DEPLOY_MODE', choices: ['local', 'ssh'], description: 'local = Jenkins runs on the app EC2; ssh = deploy to a remote EC2')
        string(name: 'EC2_HOST', defaultValue: '', description: 'EC2 public IP/DNS (ssh mode)')
        string(name: 'EC2_USER', defaultValue: 'ubuntu', description: 'SSH user (ssh mode)')
        string(name: 'APP_URL', defaultValue: 'http://localhost', description: 'URL Jenkins uses to validate the deployment')
        booleanParam(name: 'SIMULATE_FAILURE', defaultValue: false, description: 'Demo: fail post-deploy validation to exercise automatic rollback')
    }

    environment {
        DOCKER_BUILDKIT = '1'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHA   = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.GIT_SHA}"
                    // params can be null on the very first run (before Jenkins registers them)
                    env.REPO      = params.DOCKERHUB_REPO ?: 'CHANGE_ME/kanban-dashboard'
                    env.TARGET_URL = params.APP_URL ?: 'http://localhost'
                    env.SIMULATE  = "${params.SIMULATE_FAILURE ?: false}"
                    env.IMAGE     = "${env.REPO}:${env.IMAGE_TAG}"
                    env.DEPLOYED  = 'false'
                    if (env.REPO.startsWith('CHANGE_ME')) {
                        error('Set DOCKERHUB_REPO (Build with Parameters, or change its default in the Jenkinsfile)')
                    }
                }
                echo "Commit ${env.GIT_SHA} -> image ${env.IMAGE}"
            }
        }

        stage('Docker Build & Tag') {
            steps {
                sh '''
                    docker build --pull \
                        --build-arg APP_VERSION="$IMAGE_TAG" \
                        -t "$REPO:$IMAGE_TAG" \
                        -t "$REPO:sha-$GIT_SHA" \
                        -t "$REPO:latest" \
                        .
                    docker image ls "$REPO"
                '''
            }
        }

        stage('Image Security Checks') {
            steps {
                sh '''
                    # 1) must not run as root
                    IMG_USER=$(docker inspect -f '{{.Config.User}}' "$REPO:$IMAGE_TAG")
                    echo "Image user: ${IMG_USER:-<empty = root>}"
                    case "$IMG_USER" in ""|root|0|0:*|root:*) echo "FAIL: image runs as root"; exit 1;; esac

                    # 2) secret scan (fails build if any secret is found) + report HIGH/CRITICAL CVEs
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                        -v trivy-cache:/root/.cache aquasec/trivy:0.56.2 image \
                        --scanners secret --exit-code 1 "$REPO:$IMAGE_TAG"
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                        -v trivy-cache:/root/.cache aquasec/trivy:0.56.2 image \
                        --scanners vuln --severity HIGH,CRITICAL --exit-code 0 "$REPO:$IMAGE_TAG"
                '''
            }
        }

        stage('Registry Login & Push') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_TOKEN')]) {
                    // single quotes: secrets are expanded by the shell, never by Groovy, and Jenkins masks them in logs
                    sh '''
                        echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
                        docker push "$REPO:$IMAGE_TAG"
                        docker push "$REPO:sha-$GIT_SHA"
                        docker push "$REPO:latest"
                    '''
                }
            }
            post { always { sh 'docker logout || true' } }
        }

        stage('Deploy to EC2 (blue-green)') {
            steps {
                script {
                    onTarget("deploy ${env.IMAGE} ${env.IMAGE_TAG}")
                    env.DEPLOYED = 'true'   // new version is live; a later failure triggers rollback
                }
            }
        }

        stage('Health Check & Validation') {
            steps {
                script { onTarget('status') }
                sh '''
                    set -e
                    URL="$TARGET_URL"
                    [ "$SIMULATE" = "true" ] && URL="$TARGET_URL/__simulated_failure__"

                    for i in $(seq 1 10); do
                        BODY=$(curl -fsS "$URL/version.json" || true)
                        echo "attempt $i: $BODY"
                        echo "$BODY" | grep -q "\\"$IMAGE_TAG\\"" && break
                        sleep 3
                    done
                    echo "$BODY" | grep -q "\\"$IMAGE_TAG\\"" || { echo "FAIL: expected version $IMAGE_TAG"; exit 1; }

                    CODE=$(curl -s -o /tmp/index.html -w '%{http_code}' "$TARGET_URL/")
                    [ "$CODE" = "200" ] || { echo "FAIL: / returned $CODE"; exit 1; }
                    grep -q 'id="root"' /tmp/index.html || { echo "FAIL: index.html missing app root"; exit 1; }
                    echo "Validation passed: $IMAGE_TAG is live at $TARGET_URL"
                '''
            }
        }
    }

    post {
        success {
            script { currentBuild.description = "LIVE ${env.IMAGE_TAG}" }
            echo "SUCCESS: ${env.IMAGE} deployed and validated."
        }
        failure {
            script {
                if (env.DEPLOYED == 'true') {
                    echo 'Post-deploy validation failed -> rolling back to previous image'
                    try {
                        onTarget('rollback')
                        currentBuild.description = "FAILED ${env.IMAGE_TAG} - rolled back"
                    } catch (err) {
                        currentBuild.description = "FAILED ${env.IMAGE_TAG} - ROLLBACK FAILED"
                        echo "Rollback failed: ${err}"
                    }
                } else {
                    currentBuild.description = "FAILED ${env.IMAGE_TAG ?: ''} - not deployed (previous version untouched)"
                    echo 'Failure before traffic switch: deploy.sh kept the previous container live.'
                }
            }
        }
        always {
            sh 'docker image prune -f || true'
        }
    }
}
