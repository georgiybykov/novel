require 'securerandom'
require 'dry/monads'

require "novel/context"

module Novel
  class Saga
    include Dry::Monads[:result]

    attr_reader :container, :workflow, :repository

    def initialize(name:, workflow:, repository:, container: Container.new)
      @name = name

      @workflow = workflow
      @repository = repository
      @container = container
    end

    def call(params: {}, saga_id: SecureRandom.uuid, context: nil)
      context = repository.find_or_create_context(saga_id, params)

      if context.not_failed?
        activity_flow_execution(context).or do |error_result|
          if workflow.next_compensation_step(context.last_competed_compensation_step)[:async]
            Failure(status: :saga_failed, compensation_result: error_result, context: context)
          else
            Failure(status: :saga_failed, compensation_result: compensation_flow_execution(context), context: context)
          end
        end
      else
        Failure(
          status: :saga_failed,
          compensation_result: compensation_flow_execution(context),
          context: context
        )
      end
    end

  private

    def activity_flow_execution(context)
      workflow.activity_steps_from(context.last_competed_step).each do |step|
        result = container.resolve("#{step[:name]}.activity").call(context)

        if result.failure?
          context.save_compensation_state(step[:name], result.failure)
          return Failure(step: step[:name], result: result, context: context)
        end

        context.save_state(step[:name], result.value!)
        return Success(status: :waiting, context: context) if workflow.next_activity_step(step[:name])[:async]
      end

      Success(status: :finish, context: context)
    end

    def compensation_flow_execution(context)
      workflow.compensation_steps_from(context.last_competed_compensation_step).map do |step|
        result = container.resolve("#{step[:name]}.compensation").call(context)
        context.save_compensation_state(step[:name], result.value!)

        if workflow.next_compensation_step(step[:name])&.fetch(:async)
          return result
        else
          result
        end
      end
    end
  end
end
