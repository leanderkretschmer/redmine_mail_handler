# Plugin routes
# See: http://guides.rubyonrails.org/routing.html

RedmineApp::Application.routes.draw do
  # Verteiler-Ansicht (Kommentare per Drag & Drop / Eingabe in andere Tickets verschieben)
  post 'mail_handler/distributor/move_comment', to: 'mail_handler_distributor#move_comment', as: 'mail_handler_distributor_move_comment'

  # Admin-Routen
  scope '/admin' do
    resources :mail_handler_admin, :only => [:index] do
      collection do
        post :test_connection
        post :test_imap_connection
        post :test_smtp_connection
        post :test_mail
        post :manual_import
        post :toggle_scheduler
        post :restart_scheduler
        post :toggle_load_balancing
        post :get_imap_folders
        post :process_deferred
        post :create_user_from_mail
        post :process_deferred_mail
        delete :delete_all_comments
        delete :delete_anonymous_comments
        delete :delete_orphaned_attachments
        get :deferred_status
        get :deferred_stats_json
        get :deferred_mails
        get :load_deferred_mails_page
        post :reload_deferred_mails
        post :rescan_deferred_mails
        post :archive_deferred_mails
        post :save_deferred_settings
        
        post :block_user
      end
    end
    resources :mail_handler_logs, :only => [:index, :show, :destroy] do
      collection do
        delete :clear
        delete :cleanup
        get :export
      end
    end
  end
end