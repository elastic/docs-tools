import org.ajoberstar.grgit.exception.GrgitException
import org.ajoberstar.grgit.Grgit
import org.gradle.api.DefaultTask
import org.gradle.api.tasks.TaskAction

class ChangeBranchTask extends DefaultTask {
	def String branch

	@TaskAction
	def work() {
		def logstash = Grgit.open("${project.buildDir}/elastic/logstash")
		def logstashDocs = Grgit.open("${project.buildDir}/elastic/logstash-docs")
		readyGit(branch, [logstash, logstashDocs])
	}


	def readyGit(branch, gits) {
		gits.each { git ->
			println "${git.repository.rootDir}: checking out ${branch}"
			git.clean(directories: true)
			git.reset(mode: org.ajoberstar.grgit.operation.ResetOp.Mode.HARD)
			try {
				git.checkout(branch: branch)
			} catch (GrgitException e) {
				git.branch.add(name: branch, startPoint: "origin/${branch}", mode: org.ajoberstar.grgit.operation.BranchAddOp.Mode.TRACK)
				git.checkout(branch: branch)
			}
		}
	}
}

