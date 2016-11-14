import org.ajoberstar.grgit.Grgit
import org.gradle.api.DefaultTask
import org.gradle.api.tasks.TaskAction

class GitCloneTask extends DefaultTask {
	def String uri

	@TaskAction
	def work() {
		def (org, repo) = uri.split("/")[-2..-1]
		repo = repo.replaceAll(/\.git$/, "")
		def outputDir = new File("${project.buildDir}/${org}/${repo}")

		outputDir.getParentFile().mkdirs()
		if (outputDir.exists()) {
			// XXX: Make this an update task? Optional?
			def git = Grgit.open(dir: outputDir)
			git.fetch()
		} else {
			Grgit.clone(dir: outputDir, uri: uri)
		}
	}
}
