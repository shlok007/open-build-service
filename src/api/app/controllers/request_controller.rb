class RequestController < ApplicationController
  #TODO: request schema validation

  # GET /request
  alias_method :index, :pass_to_source

  # POST /request?cmd=create
  alias_method :create, :dispatch_command

  # GET /request/:id
  def show
    # parse and rewrite the request to latest format
    data = Suse::Backend.get("/request/#{params[:id]}").body
    req = BsRequest.new(data)
    send_data(req.dump_xml, :type => "text/xml")
  end

  # POST /request/:id? :cmd :newstate
  alias_method :modify, :dispatch_command

  # PUT /request/:id
  def update
    params[:user] = @http_user.login if @http_user
    
    #TODO: allow PUT for non-admins
    unless @http_user.is_admin?
      render_error :status => 403, :errorcode => 'put_request_no_permission',
        :message => "PUT on requests currently requires admin privileges"
    end

    path = request.path
    path << build_query_from_hash(params, [:user])
    forward_data path, :method => :put, :data => request.body
  end

  # DELETE /request/:id
  #def destroy
  # Do we want to allow to delete requests at all ?
  #end

  private

  def find_reviewers(obj)
    # obj can be a project or package object
    reviewers = Array.new(0)
    prj = nil

    # check for reviewers in a package first
    if obj.class == DbProject
      prj = obj
    elsif obj.class == DbPackage
      obj.package_user_role_relationships.find(:all, :conditions => ["role_id = ?", Role.find_by_title("reviewer").id] ).each do |r|
        reviewers << User.find_by_id(r.bs_user_id)
      end
      prj = obj.db_project
    else
    end

    # add reviewers of project in any case
    prj.project_user_role_relationships.find(:all, :conditions => ["role_id = ?", Role.find_by_title("reviewer").id] ).each do |r|
      reviewers << User.find_by_id(r.bs_user_id)
    end
    return reviewers
  end

  # POST /request?cmd=create
  def create_create
    req = BsRequest.new(request.body.read)

    req.each_action do |action|
      if action.data.attributes["type"] == "delete"
        #check existence of target
        tprj = DbProject.find_by_name action.target.project
        if tprj
          if action.target.has_attribute? 'package'
            tpkg = tprj.db_packages.find_by_name action.target.package
            unless tpkg
              render_error :status => 404, :errorcode => 'unknown_package',
                :message => "Unknown package  #{action.target.project} / #{action.target.package}"
              return
            end
          end
        else
          unless DbProject.find_remote_project(action.target.project)
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "Project is on remote instance, delete not possible  #{action.target.project}"
            return
          end
          render_error :status => 404, :errorcode => 'unknown_project',
            :message => "Unknown project #{action.target.project}"
          return
        end
      elsif action.data.attributes["type"] == "submit" or action.data.attributes["type"] == "change_devel"
        #check existence of source
        sprj = DbProject.find_by_name action.source.project
#        unless sprj or DbProject.find_remote_project(action.source.project)
        unless sprj
          render_error :status => 404, :errorcode => 'unknown_project',
            :message => "Unknown source project #{action.source.project}"
          return
        end

        unless action.data.attributes["type"] == "change_devel" and action.source.package.nil?
          # source package is required for submit, but optional for change_devel
          spkg = sprj.db_packages.find_by_name action.source.package
#          unless spkg or DbProject.find_remote_project(action.source.package)
          unless spkg
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "Unknown source package #{action.source.package} in project #{action.source.project}"
            return
          end
        end

        # source update checks
        if action.data.attributes["type"] == "submit"
          sourceupdate = nil
          if action.has_element? 'options' and action.options.has_element? 'sourceupdate'
             sourceupdate = action.options.sourceupdate.text
          end
          # cleanup implicit home branches, should be done in client with 2.0
          if not sourceupdate and action.has_element? :target
             if "home:#{@http_user.login}:branches:#{action.target.project}" == action.source.project
               if not action.has_element? 'options'
                 action.add_element 'options'
               end
               sourceupdate = 'cleanup'
               e = action.options.add_element 'sourceupdate'
               e.text = sourceupdate
             end
          end
          # allow cleanup only, if no devel package reference
          if sourceupdate == 'cleanup'
            unless spkg.develpackages.empty?
              msg = "Unable to delete package #{spkg.name}; following packages use this package as devel package: "
              msg += spkg.develpackages.map {|dp| dp.db_project.name+"/"+dp.name}.join(", ")
              render_error :status => 400, :errorcode => 'develpackage_dependency',
                :message => msg
              return
            end
          end
        end

        if action.data.attributes["type"] != "submit" or action.has_element? 'target'
          # target is required for change_devel, but optional for submit
          tprj = DbProject.find_by_name action.target.project
#          unless sprj or DbProject.find_remote_project(action.source.project)
          unless tprj
            render_error :status => 404, :errorcode => 'unknown_project',
              :message => "Unknown target project #{action.target.project}"
            return
          end
          if action.data.attributes["type"] == "change_devel"
            tpkg = tprj.db_packages.find_by_name action.target.package
            unless tpkg
              render_error :status => 404, :errorcode => 'unknown_package',
                :message => "Unknown target package #{action.target.package}"
              return
            end
          end
        end

        # We only allow submit/change_devel requests from projects where people have write access
        # to avoid that random people can submit versions without talking to the maintainers 
        if spkg
          unless @http_user.can_modify_package? spkg
            render_error :status => 403, :errorcode => "create_request_no_permission",
              :message => "No permission to create request for package '#{spkg.name}' in project '#{sprj.name}'"
            return
          end
        else
          unless @http_user.can_modify_project? sprj
            render_error :status => 403, :errorcode => "create_request_no_permission",
              :message => "No permission to create request based on project '#{sprj.name}'"
            return
          end
        end

      else
        render_error :status => 403, :errorcode => "create_unknown_request",
          :message => "Request type is unknown '#{action.data.attributes["type"]}'"
        return
      end
    end


    params[:user] = @http_user.login if @http_user
    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment])
    # forward_path is not working here, because we may modify the request.
    # can get cleaned up when we moved this to the client
    response = backend_post( path, req.dump_xml )

    # check targets for defined default reviewers
    reviewers = []
    req = BsRequest.new(response)
    req.each_action do |action|
      tprj = DbProject.find_by_name action.target.project
      if action.target.has_attribute? 'package'
        tpkg = tprj.db_packages.find_by_name action.target.package
        reviewers += find_reviewers(tpkg)
      else
        reviewers += find_reviewers(tprj)
      end
    end

    if reviewers.length > 0
      reviewers.each do |r|
        p = {}
        p[:cmd]     = "addreview"
        p[:by_user] = r.login
        path = "/request/" + req.id + build_query_from_hash(p, [:cmd, :by_user])
        r = backend_post( path, "" )
      end
    end

    send_data( response, :disposition => "inline" )
    return
  end

  def modify_addreview
     modify_changestate# :cmd => "addreview",
                       # :by_user => params[:by_user], :by_group => params[:by_group]
  end
  def modify_changereviewstate
     modify_changestate # :cmd => "changereviewstate", :newstate => params[:newstate], :comment => params[:comment],
                        #:by_user => params[:by_user], :by_group => params[:by_group]
  end
  def modify_changestate
    req = BsRequest.find params[:id]
    unless req
      render_error :status => 404, :message => "No such request", :errorcode => "no_such_request"
    end
    if not @http_user or not @http_user.login
      render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Action requires authentifacted user."
      return
    end
    params[:user] = @http_user.login

    # transform request body into query parameter 'comment'
    # the query parameter is preferred if both are set
    if params[:comment].blank? and request.body
      params[:comment] = request.body.read
    end

    if req.has_element? 'submit' and req.has_attribute? 'type'
      # old style, convert to new style on the fly
      node = req.submit
      node.data.name = 'action'
      node.data.attributes['type'] = 'submit'
      req.delete_attribute('type')
    end
    path = request.path + build_query_from_hash(params, [:cmd, :user, :newstate, :by_user, :by_group, :superseded_by, :comment])

    # generic permission check
    permission_granted = false
    if @http_user.is_admin?
      permission_granted = true
    elsif params[:newstate] == "deleted"
      render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Deletion of a request is only permitted for administrators. Please revoke the request instead."
      return
    elsif params[:newstate] == "superseded" and not params[:superseded_by]
      render_error :status => 403, :errorcode => "post_request_missing_parameter",
               :message => "Supersed a request requires a 'superseded_by' parameter with the request id."
      return
    elsif (params[:cmd] == "addreview" and req.creator == @http_user.login)
      # allow request creator to add further reviewers
      permission_granted = true
#    elsif (params[:cmd] == "changereviewstate" and params[:by_group] == # FIXME: support groups
#      permission_granted = true
    elsif (params[:cmd] == "changereviewstate" and params[:by_user] == @http_user.login)
      permission_granted = true
    elsif (req.state.name == "new" or req.state.name == "review") and (params[:newstate] == "superseded" or params[:newstate] == "revoked") and req.creator == @http_user.login
      # allow new -> revoked state change to creators of request
      permission_granted = true
    else # check this for changestate (of request) and addreview command
       # do not allow direct switches from accept to decline or vice versa or double actions
       if params[:newstate] == "accepted" or params[:newstate] == "declined" or params[:newstate] == "superseded"
          if req.state.name == "accepted" or req.state.name == "declined" or req.state.name == "superseded"
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "set state to #{params[:newstate]} from accepted, superseded or declined is not allowed."
             return
          end
       end
       # Do not accept to skip the review, except force argument is given
       if params[:newstate] == "accepted"
          if req.state.name == "review" and not params[:force]
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Request is in review state."
             return
          end
       end

       # permission check for each request inside
       req.each_action do |action|
         if action.data.attributes["type"] == "submit" or action.data.attributes["type"] == "change_devel"
           source_project = DbProject.find_by_name(action.source.project)
           target_project = DbProject.find_by_name(action.target.project)
           if target_project.nil?
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Target project is missing for request #{req.id} (type #{action.data.attributes['type']})"
             return
           end
           if action.target.package.nil? and action.data.attributes["type"] == "change_devel"
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Target package is missing in request #{req.id} (type #{action.data.attributes['type']})"
             return
           end
           if params[:newstate] != "declined" and params[:newstate] != "revoked"
             if source_project.nil?
               render_error :status => 403, :errorcode => "post_request_no_permission",
                 :message => "Source project is missing for request #{req.id} (type #{action.data.attributes['type']})"
               return
             else
               source_package = source_project.db_packages.find_by_name(action.source.package)
             end
             if source_package.nil? and params[:newstate] != "revoked"
               render_error :status => 403, :errorcode => "post_request_no_permission",
                 :message => "Source package is missing for request #{req.id} (type #{action.data.attributes['type']})"
               return
             end
           end
           if action.target.has_attribute? :package
             target_package = target_project.db_packages.find_by_name(action.target.package)
           else
             target_package = target_project.db_packages.find_by_name(action.source.package)
           end
           if ( target_package and @http_user.can_modify_package? target_package ) or
              ( not target_package and @http_user.can_modify_project? target_project )
              permission_granted = true
           elsif source_project and req.state.name == "new" and params[:newstate] == "revoked" 
              # source project owners should be able to revoke submit requests as well
              source_package = source_project.db_packages.find_by_name(action.source.package)
              if ( source_package and @http_user.can_modify_package? source_package ) or
                 ( not source_package and @http_user.can_modify_project? source_project )
                permission_granted = true
              else
                render_error :status => 403, :errorcode => "post_request_no_permission",
                  :message => "No permission to revoke request #{req.id} (type #{action.data.attributes['type']})"
                return
              end
           else
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "No permission to change state of request #{req.id} to #{params[:newstate]} (type #{action.data.attributes['type']})"
             return
           end
    
         elsif action.data.attributes["type"] == "delete"
           # check permissions for delete
           project = DbProject.find_by_name(action.target.project)
           package = nil
           if action.target.has_attribute? :package
              package = project.db_packages.find_by_name(action.target.package)
           end
           if @http_user.can_modify_project? project or ( package and @http_user.can_modify_package? package )
             permission_granted = true
           else
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "No permission to change state of delete request #{req.id} (type #{action.data.attributes['type']})"
             return
           end
         else
           render_error :status => 403, :errorcode => "post_request_no_permission",
             :message => "Unknown request type #{params[:newstate]} of request #{req.id} (type #{action.data.attributes['type']})"
           return
         end
      end
    end

    # at this point permissions should be granted, but let's double check
    if permission_granted != true
      render_error :status => 403, :errorcode => "post_request_no_permission",
        :message => "No permission to change state of request #{req.id} (INTERNAL ERROR, PLEASE REPORT ! )"
      return
    end

    # We have permission to change all requests inside, now execute
    req.each_action do |action|
      if action.data.attributes["type"] == "change_devel"
        if params[:newstate] == "accepted"
          target_project = DbProject.find_by_name(action.target.project)
          target_package = target_project.db_packages.find_by_name(action.target.package)
          target_package.develpackage = DbPackage.find_by_project_and_name(action.source.project, action.source.package)
          begin
            target_package.resolve_devel_package
            target_package.store
          rescue DbPackage::CycleError => e
            render_error :status => 403, :errorcode => "devel_cycle", :message => e.message
            return
          end
          render_ok
        end
      elsif action.data.attributes["type"] == "submit"
        if params[:newstate] == "accepted"
          sourceupdate = nil
          if action.has_element? 'options' and action.options.has_element? 'sourceupdate'
            sourceupdate = action.options.sourceupdate.text
          end
          src = action.source
          comment = "Copy from #{src.project}/#{src.package} via accept of submit request #{params[:id]}"
          comment += " revision #{src.rev}" if src.has_attribute? :rev
          comment += ".\n"
          comment += "Request was accepted with message:\n#{params[:comment]}\n" if params[:comment]
          cp_params = {
            :cmd => "copy",
            :user => @http_user.login,
            :oproject => src.project,
            :opackage => src.package,
            :requestid => params[:id],
            :comment => comment
          }
          cp_params[:orev] = src.rev if src.has_attribute? :rev
          cp_params[:dontupdatesource] = 1 if sourceupdate == "noupdate"

          #create package unless it exists already
          target_project = DbProject.find_by_name(action.target.project)
          if action.target.has_attribute? :package
            target_package = target_project.db_packages.find_by_name(action.target.package)
          else
            target_package = target_project.db_packages.find_by_name(action.source.package)
          end
          unless target_package
            source_project = DbProject.find_by_name(action.source.project)
            source_package = source_project.db_packages.find_by_name(action.source.package)
            target_package = Package.new(source_package.to_axml, :project => action.target.project)
            target_package.name = action.target.package
            target_package.remove_all_persons
            target_package.remove_all_flags
            target_package.remove_devel_project
            target_package.save
          end

          cp_path = "/source/#{action.target.project}/#{action.target.package}"
          cp_path << build_query_from_hash(cp_params, [:cmd, :user, :oproject, :opackage, :orev, :expand, :comment, :requestid, :dontupdatesource])
          Suse::Backend.post cp_path, nil

          # cleanup source project
          if sourceupdate == "cleanup"
            source_project = DbProject.find_by_name(action.source.project)
            source_package = source_project.db_packages.find_by_name(action.source.package)
            # check for devel package defines
            unless source_package.develpackages.empty?
              msg = "Unable to delete package #{source_package.name}; following packages use this package as devel package: "
              msg += source_package.develpackages.map {|dp| dp.db_project.name+"/"+dp.name}.join(", ")
              render_error :status => 400, :errorcode => 'develpackage_dependency',
                :message => msg
              return
            end
            if source_project.db_packages.count == 1
              #find linking repos
              lreps = Array.new
              source_project.repositories.each do |repo|
                repo.linking_repositories.each do |lrep|
                  lreps << lrep
                end
              end
              if lreps.length > 0
                #replace links to this projects with links to the "deleted" project
                del_repo = DbProject.find_by_name("deleted").repositories[0]
                lreps.each do |link_rep|
                  pe = link_rep.path_elements.find(:first, :include => ["link"], :conditions => ["db_project_id = ?", pro.id])
                  pe.link = del_repo
                  pe.save
                  #update backend
                  link_prj = link_rep.db_project
                  logger.info "updating project '#{link_prj.name}'"
                  Suse::Backend.put_source "/source/#{link_prj.name}/_meta", link_prj.to_axml
                end
              end

              # remove source project, if this is the only package
              source_project.destroy
              Suse::Backend.delete "/source/#{action.source.project}"
            else
              # just remove package
              source_package.destroy
              Suse::Backend.delete "/source/#{action.source.project}/#{action.source.package}"
            end
          end
        end
      elsif action.data.attributes["type"] == "delete"
        if params[:newstate] == "accepted" # and req.state.name != "accepted" and req.state.name != "declined"
          project = DbProject.find_by_name(action.target.project)
          unless project
            msg = "Unable to delete project #{action.target.project}; it does not exist."
            render_error :status => 400, :errorcode => 'not_existing_target',
              :message => msg
            return
          end
          if not action.target.has_attribute? :package
            project.destroy
            Suse::Backend.delete "/source/#{action.target.project}"
          else
            DbPackage.transaction do
              package = project.db_packages.find_by_name(action.target.package)
              unless package
                msg = "Unable to delete package #{action.target.project}/#{action.target.package}; it does not exist."
                render_error :status => 400, :errorcode => 'not_existing_target',
                  :message => msg
                return
              end
              package.destroy
              Suse::Backend.delete "/source/#{action.target.project}/#{action.target.package}"
            end
          end
          render_ok
        end
      else
        render_error :status => 403, :errorcode => "post_request_no_permission",
          :message => "Failed to execute request state change of request #{req.id} (type #{action.data.attributes['type']})"
        return
      end
    end
    forward_data path, :method => :post
  end
end
